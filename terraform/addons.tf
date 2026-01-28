# 1. Install NGINX Ingress Controller
resource "helm_release" "nginx_ingress" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = "4.8.3"
  depends_on       = [azurerm_kubernetes_cluster.aks]

  # ERROR WAS HERE: Removed "set = [" and "]"
  # FIX: Use repeated 'set' blocks
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-health-probe-request-path"
    value = "/healthz"
  }

  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-dns-label-name"
    value = "tapan-gitops-app" # <--- Ensure this is unique
  }

  # This stops NGINX from forcing 'http' users to go to 'https'
  set {
    name  = "controller.config.ssl-redirect"
    value = "false"
  }
}

# 2. Install Argo CD
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "5.46.7"
  depends_on       = [azurerm_kubernetes_cluster.aks]

  # 1. Use ClusterIP (Hidden behind Nginx)
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  # 2. Disable internal TLS (Let Nginx handle SSL)
  set {
    name  = "server.insecure"
    value = "true"
  }

  # 3. CRITICAL: Tell Argo it is running on a sub-path
  set {
    name  = "server.basehref"
    value = "/argocd"
  }

  set {
    name  = "server.rootpath"
    value = "/argocd"
  }
  set {
    name  = "server.extraArgs[0]"
    value = "--rootpath=/argocd"
  }
  # 4. Configure the Ingress Rule for Argo
  set {
    name  = "server.ingress.enabled"
    value = "false"
  }

  set {
    name  = "server.ingress.ingressClassName"
    value = "nginx"
  }

  set {
    name  = "server.ingress.path"
    value = "/argocd"
  }

  # This adds an annotation to the Argo CD Ingress specifically
  set {
    name  = "server.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/ssl-redirect"
    value = "false"
  }

  
}

# 3. Install Argo Rollouts
resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  namespace        = "argo-rollouts"
  create_namespace = true
  version          = "2.32.0"
  depends_on       = [azurerm_kubernetes_cluster.aks]
  
  set {
    name  = "dashboard.enabled"
    value = "true"
  }
set {
    name  = "dashboard.ingress.enabled"  # <--- CHANGED THIS from 'server'
    value = "false"
  }
  
}

# 4. Bootstrap the Cluster (Apply root-app.yaml)
resource "kubectl_manifest" "argocd_root_app" {
    yaml_body = file("${path.module}/../k8s/bootstrap/root-app.yaml")
    depends_on = [helm_release.argocd]
}