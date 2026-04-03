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

# ─── NGINX Ingress Controller (co-exists with AGC) ─────────────
# AGC uses Gateway API CRDs; NGINX uses standard Ingress resources.
# Both controllers run independently on the same cluster.

resource "helm_release" "nginx_ingress_cluster1" {
  provider         = helm.cluster1
  name             = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"

  # Internal Azure Load Balancer (stays within VNet)
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-internal"
    value = "true"
    type  = "string"
  }

  # Static IP from AKS1 subnet
  set {
    name  = "controller.service.loadBalancerIP"
    value = local.nginx_ilb_ip
  }

  # Use a distinct ingress class so it doesn't conflict with AGC
  set {
    name  = "controller.ingressClassResource.name"
    value = "nginx"
  }

  set {
    name  = "controller.ingressClassResource.default"
    value = "false"
  }

  depends_on = [azurerm_kubernetes_cluster.aks1]
}

# ── NGINX Ingress Resources (legacy pods routed via NGINX) ─────
resource "kubernetes_deployment_v1" "nginx_legacy" {
  provider = kubernetes.cluster1

  metadata {
    name      = "legacy-app"
    namespace = kubernetes_namespace_v1.cluster1.metadata[0].name
    labels    = { app = "legacy-app" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "legacy-app" }
    }
    template {
      metadata {
        labels = { app = "legacy-app" }
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
            value = "legacy"
          }
          env {
            name  = "CLUSTER_NAME"
            value = "cluster1-nginx"
          }
          env {
            name  = "INGRESS_TYPE"
            value = "nginx"
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

resource "kubernetes_service_v1" "nginx_legacy" {
  provider = kubernetes.cluster1

  metadata {
    name      = "legacy-app"
    namespace = kubernetes_namespace_v1.cluster1.metadata[0].name
  }

  spec {
    selector = { app = "legacy-app" }
    port {
      port        = 8080
      target_port = 8080
    }
    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "nginx_legacy" {
  provider = kubernetes.cluster1

  metadata {
    name      = "ingress-legacy"
    namespace = kubernetes_namespace_v1.cluster1.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/rewrite-target" = "/$2"
    }
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      http {
        path {
          path      = "/legacy(/|$)(.*)"
          path_type = "ImplementationSpecific"
          backend {
            service {
              name = "legacy-app"
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.nginx_ingress_cluster1]
}

# ─── Frontend on AKS (static HTML served by NGINX container) ──
# Demonstrates hosting static frontend files inside AKS,
# routed via NGINX Ingress Controller (bypassing APIM for static content).

resource "kubernetes_namespace_v1" "frontend" {
  provider = kubernetes.cluster1
  metadata {
    name = "frontend"
  }
}

resource "kubernetes_config_map_v1" "frontend_html" {
  provider = kubernetes.cluster1

  metadata {
    name      = "frontend-html"
    namespace = kubernetes_namespace_v1.frontend.metadata[0].name
  }

  data = {
    "index.html" = templatefile("${path.module}/templates/aks-frontend.html.tftpl", {
      client_id = azuread_application.main.client_id
      tenant_id = data.azurerm_client_config.current.tenant_id
      base_url  = "https://${local.hostname}"
    })
  }
}

resource "kubernetes_deployment_v1" "frontend" {
  provider = kubernetes.cluster1

  metadata {
    name      = "frontend"
    namespace = kubernetes_namespace_v1.frontend.metadata[0].name
    labels    = { app = "frontend" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "frontend" }
    }
    template {
      metadata {
        labels = { app = "frontend" }
      }
      spec {
        container {
          name  = "nginx"
          image = "nginx:1.27-alpine"

          port {
            container_port = 80
          }

          volume_mount {
            name       = "html"
            mount_path = "/usr/share/nginx/html"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "50m", memory = "64Mi" }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
        }

        volume {
          name = "html"
          config_map {
            name = kubernetes_config_map_v1.frontend_html.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "frontend" {
  provider = kubernetes.cluster1

  metadata {
    name      = "frontend"
    namespace = kubernetes_namespace_v1.frontend.metadata[0].name
  }

  spec {
    selector = { app = "frontend" }
    port {
      port        = 80
      target_port = 80
    }
    type = "ClusterIP"
  }
}

# ── NGINX Ingress for Frontend (static content via NGINX ILB) ──
resource "kubernetes_ingress_v1" "nginx_frontend" {
  provider = kubernetes.cluster1

  metadata {
    name      = "ingress-frontend"
    namespace = kubernetes_namespace_v1.frontend.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/rewrite-target" = "/$2"
    }
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      http {
        path {
          path      = "/aks-app(/|$)(.*)"
          path_type = "ImplementationSpecific"
          backend {
            service {
              name = "frontend"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.nginx_ingress_cluster1]
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
