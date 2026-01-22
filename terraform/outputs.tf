output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
  description = "The URL needed to push docker images"
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "get_credentials_command" {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name}"
  description = "Run this command to connect your local kubectl to the new cluster"
}
