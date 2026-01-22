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