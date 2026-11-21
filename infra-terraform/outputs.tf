output "resource_group" {
  value = azurerm_resource_group.rg.name
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "key_vault_name" {
  value = azurerm_key_vault.kv.name
}

output "db_fqdn" {
  value = azurerm_postgresql_flexible_server.db.fqdn
}

output "app_identity_client_id" {
  value = azurerm_user_assigned_identity.app.client_id
}