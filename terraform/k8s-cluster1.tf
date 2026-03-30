# ─── Cluster 1: K8s Resources (AGC Ingress) ─────────────────────

# Namespace
resource "kubernetes_namespace_v1" "cluster1" {
  provider = kubernetes.cluster1
  metadata {
    name = "demo-apis"
  }
}

# ── ALB Controller Helm Chart ──────────────────────────────────
resource "helm_release" "alb_controller" {
  provider         = helm.cluster1
  name             = "alb-controller"
  namespace        = "azure-alb-system"
  create_namespace = true
  repository       = "oci://mcr.microsoft.com/application-lb/charts"
  chart            = "alb-controller"
  version          = "1.3.7"

  set {
    name  = "albController.namespace"
    value = "azure-alb-system"
  }

  set {
    name  = "albController.podIdentity.clientID"
    value = azurerm_user_assigned_identity.alb_controller.client_id
  }

  depends_on = [
    azurerm_federated_identity_credential.alb_controller,
    azurerm_kubernetes_cluster.aks1,
  ]
}

# ── API Deployments ────────────────────────────────────────────
resource "kubernetes_deployment_v1" "cluster1" {
  provider = kubernetes.cluster1
  for_each = toset(local.api_services)

  metadata {
    name      = "api-${each.key}"
    namespace = kubernetes_namespace_v1.cluster1.metadata[0].name
    labels    = { app = "api-${each.key}" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "api-${each.key}" }
    }
    template {
      metadata {
        labels = { app = "api-${each.key}" }
      }
      spec {
        container {
          name  = "api"
          image = "${azurerm_container_registry.main.login_server}/demo-api:latest"

          port {
            container_port = 8080
          }

          env {
            name  = "SERVICE_NAME"
            value = each.key
          }
          env {
            name  = "CLUSTER_NAME"
            value = "cluster1-agc"
          }
          env {
            name  = "INGRESS_TYPE"
            value = "agc"
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "250m", memory = "256Mi" }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }

  depends_on = [azurerm_role_assignment.aks1_acr]
}

# ── Services ────────────────────────────────────────────────────
resource "kubernetes_service_v1" "cluster1" {
  provider = kubernetes.cluster1
  for_each = toset(local.api_services)

  metadata {
    name      = "api-${each.key}"
    namespace = kubernetes_namespace_v1.cluster1.metadata[0].name
  }

  spec {
    selector = { app = "api-${each.key}" }
    port {
      port        = 8080
      target_port = 8080
    }
    type = "ClusterIP"
  }
}

# ── Gateway API Resources (applied via kubectl) ────────────────
# The Gateway API CRDs are installed by the ALB controller Helm chart.
# We use a rendered YAML file + null_resource to apply custom resources.

resource "local_file" "agc_gateway_yaml" {
  content = templatefile("${path.module}/templates/agc-gateway.yaml.tftpl", {
    namespace     = kubernetes_namespace_v1.cluster1.metadata[0].name
    agc_id        = azurerm_application_load_balancer.main.id
    frontend_name = azurerm_application_load_balancer_frontend.main.name
  })
  filename = "${path.module}/.generated/agc-gateway.yaml"
}

resource "null_resource" "apply_agc_gateway" {
  triggers = {
    yaml_hash = local_file.agc_gateway_yaml.content_md5
  }

  provisioner "local-exec" {
    command     = <<-EOT
      az aks get-credentials --resource-group "${azurerm_resource_group.main.name}" --name "${azurerm_kubernetes_cluster.aks1.name}" --overwrite-existing --admin
      kubectl apply -f "${replace(local_file.agc_gateway_yaml.filename, "\\", "/")}"
    EOT
    interpreter = ["PowerShell", "-Command"]
  }

  depends_on = [
    helm_release.alb_controller,
    kubernetes_service_v1.cluster1,
  ]
}
