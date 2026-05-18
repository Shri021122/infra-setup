################################################################################
# ArgoCD private Ingress + Cilium L2 announcement + cert-manager Certificate
#
# All four resources gate on var.argocd_ingress_enabled. Flip it once:
#   - rke2/scripts/apply-cilium-config.sh has been run (l2announcements=true)
#   - your internal DNS has argocd.<domain> → 10.10.18.200
################################################################################

locals {
  ingress_count = var.argocd_ingress_enabled ? 1 : 0
  lb_ip         = split("/", var.argocd_lb_ip_pool_cidr)[0]

  ingress_instructions = <<-EOT
    ─── ArgoCD Ingress ────────────────────────────────────────────────────────

    URL:         https://${var.argocd_hostname}
    LB IP:       ${local.lb_ip}
    Issuer:      ${var.argocd_cluster_issuer}

    Client prerequisites:
      1. Internal DNS: ${var.argocd_hostname} → ${local.lb_ip}
         (or add to /etc/hosts on each client)

      2. Trust the CA: import the cluster CA into your laptop trust store
         (same cert your Hubble UI uses — cert-manager 'cluster-ca-issuer')

      3. CLI:  argocd login ${var.argocd_hostname} --grpc-web
         (--grpc-web is needed because TLS terminates at the Ingress and the
          backend speaks plain HTTP)

    Verify LB IP assignment:
      kubectl -n kube-system get svc cilium-ingress
      → EXTERNAL-IP should show ${local.lb_ip}

    Verify cert issued:
      kubectl -n ${var.argocd_namespace} get certificate argocd-server-tls
      → READY=True within ~30s
    ───────────────────────────────────────────────────────────────────────────
  EOT
}

# ─── Cilium LoadBalancer IP pool ─────────────────────────────────────────────
# Pool the cilium-ingress LoadBalancer service draws from. /32 = exactly one
# IP today (10.10.18.200). Adding more services later: edit the CR.
resource "kubectl_manifest" "lb_ip_pool" {
  count = local.ingress_count

  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumLoadBalancerIPPool"
    metadata = {
      name = "argocd-pool"
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = {
      blocks = [
        { cidr = var.argocd_lb_ip_pool_cidr }
      ]
    }
  })
}

# ─── Cilium L2 Announcement Policy ───────────────────────────────────────────
# Tells Cilium which nodes can ARP-announce LB IPs and on which interfaces.
# Workers only (masters shouldn't carry user traffic).
resource "kubectl_manifest" "l2_announce_policy" {
  count      = local.ingress_count
  depends_on = [kubectl_manifest.lb_ip_pool]

  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumL2AnnouncementPolicy"
    metadata = {
      name = "argocd-l2-announce"
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = {
      # Announce every LoadBalancer service that lands in this pool
      loadBalancerIPs = true
      externalIPs     = false
      interfaces      = [var.argocd_lb_l2_interface_regex]
      nodeSelector = {
        matchExpressions = [{
          key      = "node-role.kubernetes.io/worker"
          operator = "Exists"
        }]
      }
    }
  })
}

# ─── cert-manager Certificate ────────────────────────────────────────────────
# Pre-creates the TLS secret so Cilium Ingress doesn't have to wait for the
# annotation-driven flow. The Ingress references the resulting secret.
resource "kubectl_manifest" "argocd_certificate" {
  count      = local.ingress_count
  depends_on = [module.argocd]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "argocd-server-tls"
      namespace = var.argocd_namespace
    }
    spec = {
      secretName = "argocd-server-tls"
      duration   = "8760h"   # 1 year
      renewBefore = "720h"   # 30 days
      commonName = var.argocd_hostname
      dnsNames   = [var.argocd_hostname]
      issuerRef = {
        kind = "ClusterIssuer"
        name = var.argocd_cluster_issuer
      }
      usages = ["digital signature", "key encipherment", "server auth"]
    }
  })
}

# ─── Ingress ─────────────────────────────────────────────────────────────────
# Cilium IngressClass terminates TLS using the secret cert-manager wrote above,
# proxies plain HTTP to argocd-server:80. argocd-server must be running with
# --insecure (set argocd_server_insecure=true in tfvars).
resource "kubernetes_ingress_v1" "argocd" {
  count = local.ingress_count

  depends_on = [
    module.argocd,
    kubectl_manifest.argocd_certificate,
  ]

  metadata {
    name      = "argocd-server"
    namespace = var.argocd_namespace

    annotations = {
      # cert-manager won't try to re-issue since the Certificate above already
      # provisions the secret; this annotation is harmless and useful for
      # operators expecting it.
      "cert-manager.io/cluster-issuer" = var.argocd_cluster_issuer

      # Force the LB IP we want (must be inside argocd_lb_ip_pool_cidr).
      # Cilium reads this off the cilium-ingress Service, but setting it here
      # makes the intent visible at the Ingress layer too.
      "ingress.cilium.io/loadbalancer-ip" = local.lb_ip
    }
  }

  spec {
    ingress_class_name = "cilium"

    tls {
      hosts       = [var.argocd_hostname]
      secret_name = "argocd-server-tls"
    }

    rule {
      host = var.argocd_hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "argocd-server"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

# ─── Outputs ─────────────────────────────────────────────────────────────────

output "argocd_ingress" {
  description = "How to reach ArgoCD after Ingress is up"
  value = (
    var.argocd_ingress_enabled
    ? local.ingress_instructions
    : "Ingress disabled — set argocd_ingress_enabled=true and re-apply."
  )
}
