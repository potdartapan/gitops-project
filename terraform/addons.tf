# 1. Install NGINX Ingress Controller
# (This is now your ONLY Public IP)
resource "helm_release" "nginx_ingress" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = "4.8.3"
  depends_on       = [azurerm_kubernetes_cluster.aks]

  set = [
    {
      name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-health-probe-request-path"
      value = "/healthz"
    },
    {
      name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-dns-label-name"
      value = "tapan-gitops-app" # <--- Must be unique in the Azure Region
    }
  ]
}

# 2. Install Argo CD (Hidden behind Nginx)
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "5.46.7"
  depends_on       = [azurerm_kubernetes_cluster.aks]

  set = [
    # 1. Use ClusterIP (Hidden behind Nginx)
    {
      name  = "server.service.type"
      value = "ClusterIP"
    },
    # 2. Disable internal TLS (Let Nginx handle SSL)
    {
      name  = "server.insecure"
      value = "true"
    },
    # 3. CRITICAL: Tell Argo it is running on a sub-path
    {
      name  = "server.basehref"
      value = "/argocd"
    },
    {
      name  = "server.rootpath"
      value = "/argocd"
    },
    # 4. Configure the Ingress Rule for Argo
    {
      name  = "server.ingress.enabled"
      value = "true"
    },
    {
      name  = "server.ingress.ingressClassName"
      value = "nginx"
    },
    {
      name  = "server.ingress.path"
      value = "/argocd"
    }
    # Note: We REMOVED the "hosts" setting. 
    # This makes it listen on ANY domain that hits the IP.
  ]
}

# 3. Argo Rollouts (Unchanged)
resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  namespace        = "argo-rollouts"
  create_namespace = true
  version          = "2.32.0"
  depends_on       = [azurerm_kubernetes_cluster.aks]
  
  set = [
    {
      name  = "dashboard.enabled"
      value = "true"
    }
  ]
}

resource "kubectl_manifest" "argocd_root_app" {
    # This reads the file from k8s/bootstrap/root-app.yaml
    yaml_body = file("${path.module}/k8s/bootstrap/root-app.yaml")
    
    # CRITICAL: Wait for Argo CD to be fully installed first
    depends_on = [helm_release.argocd]
}