data "azurerm_client_config" "current" {}

# --- Container Registry (günstigste Stufe, kein Admin-Benutzer) ---
resource "azurerm_container_registry" "acr" {
  name                = "acr${var.prefix}${var.suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false
}

# --- Identität für die Pods (Workload Identity, Verknüpfung kommt mit AKS) ---
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${var.prefix}-app"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

# --- Key Vault ---
resource "azurerm_key_vault" "kv" {
  name                       = "kv-${var.prefix}-${var.suffix}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
}

# Du (Terraform) darfst Secrets schreiben
resource "azurerm_key_vault_access_policy" "terraform" {
  key_vault_id       = azurerm_key_vault.kv.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = data.azurerm_client_config.current.object_id
  secret_permissions = ["Get", "List", "Set", "Delete", "Purge", "Recover"]
}

# Die Pods dürfen Secrets nur lesen
resource "azurerm_key_vault_access_policy" "app" {
  key_vault_id       = azurerm_key_vault.kv.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = azurerm_user_assigned_identity.app.principal_id
  secret_permissions = ["Get", "List"]
}

# --- Zufälliges DB-Passwort (steht nie im Code) ---
resource "random_password" "db" {
  length  = 24
  special = false
}

# --- PostgreSQL Flexible Server (privat, günstigste Stufe) ---
resource "azurerm_postgresql_flexible_server" "db" {
  name                          = "psql-${var.prefix}-${var.suffix}"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = azurerm_resource_group.rg.location
  version                       = "16"
  sku_name                      = "B_Standard_B1ms"
  storage_mb                    = 32768
  backup_retention_days         = 7
  delegated_subnet_id           = azurerm_subnet.db.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false
  administrator_login           = var.db_admin_login
  administrator_password        = random_password.db.result

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = "learning_journal"
  server_id = azurerm_postgresql_flexible_server.db.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# --- Secrets im Key Vault ---
resource "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  value        = random_password.db.result
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "database_url" {
  name         = "database-url"
  value        = "postgresql://${var.db_admin_login}:${random_password.db.result}@${azurerm_postgresql_flexible_server.db.fqdn}:5432/${azurerm_postgresql_flexible_server_database.app.name}"
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault_access_policy.terraform]
}