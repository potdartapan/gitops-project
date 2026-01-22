# 1. Resource Group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# 2. Random String
# Azure requires globally unique names for ACR. This adds a random suffix (e.g., devopsacr9x8y)
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# 3. Azure Container Registry (ACR)
resource "azurerm_container_registry" "acr" {
  name                = "${var.acr_name_prefix}${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic" # "Basic" is cheapest and sufficient for learning
  admin_enabled       = true
}

# 4. Azure Kubernetes Service (AKS)
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "devopsaks"

  default_node_pool {
    name       = "default"
    node_count = var.node_count
    vm_size    = "Standard_B2s" # Cost-effective burstable VM
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    Environment = "DevOps-Portfolio"
  }
}

# 5. Role Assignment: Allow AKS to pull images from ACR
# This is CRITICAL. Without this, your pods will fail with "ImagePullBackOff"
resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.acr.id
  skip_service_principal_aad_check = true
}
