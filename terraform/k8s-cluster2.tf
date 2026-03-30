# ─── Cluster 2: K8s Resources (Traefik + Internal LB) ───────────

# Namespace
resource "kubernetes_namespace_v1" "cluster2" {
  provider = kubernetes.cluster2
  metadata {
    name = "demo-apis"
  }
}

# ── Traefik Helm Chart ─────────────────────────────────────────
resource "helm_release" "traefik" {
  provider         = helm.cluster2
  name             = "traefik"
  namespace        = "traefik"
  create_namespace = true
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"

  # Use internal Azure Load Balancer
  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-internal"
    value = "true"
    type  = "string"
  }

  # Static IP from AKS2 subnet
  set {
    name  = "service.spec.loadBalancerIP"
    value = local.traefik_ilb_ip
  }

  # Enable Kubernetes Ingress provider
  set {
    name  = "providers.kubernetesIngress.enabled"
    value = "true"
  }

  set {
    name  = "providers.kubernetesIngress.allowExternalNameServices"
    value = "true"
  }

  depends_on = [azurerm_kubernetes_cluster.aks2]
}

# ── API Deployments ────────────────────────────────────────────
resource "kubernetes_deployment_v1" "cluster2" {
  provider = kubernetes.cluster2
  for_each = toset(local.api_services)

  metadata {
    name      = "api-${each.key}"
    namespace = kubernetes_namespace_v1.cluster2.metadata[0].name
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
            value = "cluster2-traefik"
          }
          env {
            name  = "INGRESS_TYPE"
            value = "traefik"
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

  depends_on = [azurerm_role_assignment.aks2_acr]
}

# ── Services ────────────────────────────────────────────────────
resource "kubernetes_service_v1" "cluster2" {
  provider = kubernetes.cluster2
  for_each = toset(local.api_services)

  metadata {
    name      = "api-${each.key}"
    namespace = kubernetes_namespace_v1.cluster2.metadata[0].name
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

# ── Ingress (Traefik) ──────────────────────────────────────────
resource "kubernetes_ingress_v1" "cluster2" {
  provider = kubernetes.cluster2
  for_each = toset(local.api_services)

  metadata {
    name      = "ingress-${each.key}"
    namespace = kubernetes_namespace_v1.cluster2.metadata[0].name
    annotations = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "web"
    }
  }

  spec {
    ingress_class_name = "traefik"

    rule {
      http {
        path {
          path      = "/${each.key}"
          path_type = "Prefix"
          backend {
            service {
              name = "api-${each.key}"
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.traefik]
}
