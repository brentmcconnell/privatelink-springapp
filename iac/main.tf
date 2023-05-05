terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "~>3.0"
    }
  }
  backend "azurerm" {
    resource_group_name   = "PRIVATE-RG"
    storage_account_name  = "tfstate11599sa"
    container_name        = "tfstate"
    key                   = "terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

variable resource_group {
  type    = string
}

variable prefix {
  type    = string
}

variable location {
  type    = string
  default = "eastus"
}

variable sp_id {
  type = string
}

variable sp_key {
  type = string
}

# Local variables.  Change these to change names
locals {
  resource_group          = data.azurerm_resource_group.project-rg.name 
  location                = var.location
  prefix                  = var.prefix 
  sp_id                   = var.sp_id
  sp_key                  = var.sp_key
  tenant_id               = data.azurerm_client_config.current.tenant_id
}

# This pulls in data from the current user and subscription
data "azurerm_client_config" "current" {} 
data "azurerm_subscription" "current" {}
data "azurerm_resource_group" "project-rg" {
  name = var.resource_group
} 
data "azuread_service_principal" "sp" {
  application_id = var.sp_id
}

# Generate a password for MySQL
resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "-_"
}

# Creates RG
# resource "azurerm_resource_group" "rg" {
#   name     = local.resource_group 
#   location = local.location 
# }

# Create private container registry
# Also imports a test image from DockerHub
resource "azurerm_container_registry" "acr" {
  name                = "${local.prefix}acr"
  resource_group_name = local.resource_group
  location            = local.location 
  sku                 = "Standard"
  admin_enabled       = true
  provisioner "local-exec" {
    when        = create
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOF
      az login --service-principal -u ${local.sp_id} -p ${local.sp_key} --tenant ${local.tenant_id}
      az acr import --force --name ${azurerm_container_registry.acr.name}  --source docker.io/emcconne/springdemo:latest --image todoapp:latest
    EOF
  }
}

# Give Managed Identity of AppService AcrPull on registry
resource "azurerm_role_assignment" "app_to_acr" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = "${lookup(azurerm_linux_web_app.backwebapp.identity[0],"principal_id")}"
}

# Give Managed Identity of AppService Slot AcrPull on registry
resource "azurerm_role_assignment" "devslot_to_acr" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = "${lookup(azurerm_linux_web_app_slot.devslot.identity[0],"principal_id")}"
  depends_on           = [ azurerm_linux_web_app_slot.devslot ]
}

# Create a Keyvault
resource "azurerm_key_vault" "vault" {
  name                      = "${local.prefix}-kv"
  location                  = local.location
  resource_group_name       = local.resource_group 
  sku_name                  = "standard"
  tenant_id                 = data.azurerm_client_config.current.tenant_id
}

# Give AppService Permissions on KeyVault
resource "azurerm_key_vault_access_policy" "app_mi" {
  key_vault_id        = azurerm_key_vault.vault.id
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = "${lookup(azurerm_linux_web_app.backwebapp.identity[0],"principal_id")}"
  secret_permissions  = [
    "Get","List",
  ]
}

# Give AppService Slot Permissions on KeyVault
resource "azurerm_key_vault_access_policy" "slot_mi" {
  key_vault_id        = azurerm_key_vault.vault.id
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = "${lookup(azurerm_linux_web_app_slot.devslot.identity[0],"principal_id")}"

  secret_permissions  = [
    "Get","List",
  ]
  depends_on           = [ azurerm_linux_web_app_slot.devslot ]
}

# Give Service Principal permissions on KeyVault
resource "azurerm_key_vault_access_policy" "sp-access" {
  key_vault_id    = azurerm_key_vault.vault.id
  tenant_id       = data.azurerm_client_config.current.tenant_id
  object_id       = data.azuread_service_principal.sp.object_id
  key_permissions = [
    "Get","List","Create","Delete","Encrypt","Decrypt","UnwrapKey","WrapKey","Purge","Recover","Restore"
  ]
  secret_permissions = [
    "Get","List","Set","Delete","Purge","Recover","Restore"
  ]
  certificate_permissions = [
    "Backup","Create","Delete","Get","Import","List","Purge","Recover","Restore","Update"
  ]
  storage_permissions = [
    "Get","List","Set","Delete","Purge","Recover","Restore"
  ]
  provisioner "local-exec" {
    command = "sleep 30"
  }
}

#Give Current User permissions on KeyVault
resource "azurerm_key_vault_access_policy" "my-access" {
  key_vault_id    = azurerm_key_vault.vault.id
  tenant_id       = data.azurerm_client_config.current.tenant_id
  object_id       = data.azurerm_client_config.current.object_id
  key_permissions = [
    "Get","List","Create","Delete","Encrypt","Decrypt","UnwrapKey","WrapKey","Purge","Recover","Restore"
  ]
  secret_permissions = [
    "Get","List","Set","Delete","Purge","Recover","Restore"
  ]
  certificate_permissions = [
    "Backup","Create","Delete","Get","Import","List","Purge","Recover","Restore","Update"
  ]
  storage_permissions = [
    "Get","List","Set","Delete","Purge","Recover","Restore"
  ]
  provisioner "local-exec" {
    command = "sleep 30"
  }
}

# Create Redis Cache as it's needed by the test application
# NOTE: the Name used for Redis needs to be globally unique
#
resource "azurerm_redis_cache" "redis" {
  name                = lower("${local.prefix}-redis")
  location            = local.location
  resource_group_name = local.resource_group 
  capacity            = 2
  family              = "C"
  sku_name            = "Standard"
  enable_non_ssl_port = true
  minimum_tls_version = "1.2"

  redis_configuration {
    notify_keyspace_events = "Egx"
  }
}

# Create MYSQL DB needed by example application
resource "azurerm_mysql_flexible_server" "dbserver" {
  name                            = "${local.prefix}-mysql"
  location                        = local.location
  resource_group_name             = local.resource_group 

  administrator_login             = "mysqladmin"
  administrator_password          = random_password.password.result

  sku_name                        = "B_Standard_B1s"
  version                         = "5.7"
  zone                            = 1
}

# NOT a best practice!! Only for this demo.  Allows NOSSL on DB
resource "azurerm_mysql_flexible_server_configuration" "nossl" {
  name                = "require_secure_transport"
  resource_group_name = local.resource_group 
  server_name         = azurerm_mysql_flexible_server.dbserver.name
  value               = "OFF"
}

# Allow services in Azure to hit database
resource "azurerm_mysql_flexible_server_firewall_rule" "allazure" {
  name                = "azure"
  resource_group_name = local.resource_group 
  server_name         = azurerm_mysql_flexible_server.dbserver.name
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
}

# Create a todo database for the example database
resource "azurerm_mysql_flexible_database" "tododb" {
  name                = "tododb"
  resource_group_name = local.resource_group 
  server_name         = azurerm_mysql_flexible_server.dbserver.name
  charset             = "utf8"
  collation           = "utf8_unicode_ci"
}

# Add values to KeyVault so that Java Spring has info it needs when running
resource "azurerm_key_vault_secret" "spring-datasource-url" {
  name         = "spring-datasource-url"
  value        = "jdbc:mysql://${azurerm_mysql_flexible_server.dbserver.fqdn}:3306/${azurerm_mysql_flexible_database.tododb.name}"
  key_vault_id = azurerm_key_vault.vault.id
  depends_on   = [azurerm_key_vault_access_policy.my-access]
}

# Add values to KeyVault so that Java Spring has info it needs when running
resource "azurerm_key_vault_secret" "spring-datasource-username" {
  name         = "spring-datasource-username"
  value        = "mysqladmin"
  key_vault_id = azurerm_key_vault.vault.id
  depends_on   = [azurerm_key_vault_access_policy.my-access]
}

# Add values to KeyVault so that Java Spring has info it needs when running
resource "azurerm_key_vault_secret" "spring-datasource-password" {
  name         = "spring-datasource-password"
  value        = random_password.password.result 
  key_vault_id = azurerm_key_vault.vault.id
  depends_on   = [azurerm_key_vault_access_policy.my-access]
}

# Add values to KeyVault so that Java Spring has info it needs when running
resource "azurerm_key_vault_secret" "spring-redis-host" {
  name         = "spring-redis-host"
  value        = azurerm_redis_cache.redis.hostname
  key_vault_id = azurerm_key_vault.vault.id
  depends_on   = [azurerm_key_vault_access_policy.my-access]
}

# Add values to KeyVault so that Java Spring has info it needs when running
resource "azurerm_key_vault_secret" "spring-redis-password" {
  name         = "spring-redis-password"
  value        = azurerm_redis_cache.redis.primary_access_key
  key_vault_id = azurerm_key_vault.vault.id
  depends_on   = [azurerm_key_vault_access_policy.my-access]
}

# Stick the ACR password in KeyVault. 
# resource "azurerm_key_vault_secret" "acr-password" {
#   name         = "acr-password"
#   value        = azurerm_container_registry.acr.admin_password 
#   key_vault_id = azurerm_key_vault.vault.id
#   depends_on   = [azurerm_key_vault_access_policy.my-access]
# }

# Give the MI of app service permission on the KeyVault
resource "azurerm_key_vault_access_policy" "app-access" {
  key_vault_id    = azurerm_key_vault.vault.id
  tenant_id       = data.azurerm_client_config.current.tenant_id
  object_id       = azurerm_linux_web_app.backwebapp.identity[0].principal_id
  key_permissions = [
    "Get","List","Create","Delete","Encrypt","Decrypt","UnwrapKey","WrapKey","Purge","Recover","Restore"
  ]
  secret_permissions = [
    "Get","List","Set","Delete","Purge","Recover","Restore"
  ]
  certificate_permissions = [
    "Backup","Create","Delete","Get","Import","List","Purge","Recover","Restore","Update"
  ]
  storage_permissions = [
    "Get","List","Set","Delete","Purge","Recover","Restore"
  ]
}

# Create VNet
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet"
  location            = local.location
  resource_group_name = local.resource_group 
  address_space       = ["10.0.0.0/16"]
}

# Create IntegrationSubnet
resource "azurerm_subnet" "integrationsubnet" {
  name                 = "integrationsubnet"
  resource_group_name  = local.resource_group 
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
  delegation {
    name = "delegation"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
    }
  }
}

# Create EndpointSubnet
resource "azurerm_subnet" "endpointsubnet" {
  name                 = "endpointsubnet"
  resource_group_name  = local.resource_group 
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
  private_endpoint_network_policies_enabled = true
}

# Create AppService Plan
resource "azurerm_service_plan" "appserviceplan" {
  name                = "appserviceplan"
  location            = local.location 
  resource_group_name = local.resource_group 
  os_type             = "Linux"
  sku_name            = "P1v2"
}

# Create a WebApp in the Appservice plan
# Use the todo image we created in the ACR using MI
resource "azurerm_linux_web_app" "backwebapp" {
  name                = "${local.prefix}-webapp"
  location            = local.location
  resource_group_name = local.resource_group 
  service_plan_id     = azurerm_service_plan.appserviceplan.id
  https_only          = true

  site_config {
    minimum_tls_version = "1.2"
    container_registry_use_managed_identity = true
    application_stack {
      docker_image      = "${azurerm_container_registry.acr.login_server}/todoapp"
      docker_image_tag  = "latest"
    }
  }

  logs {
    application_logs {
      file_system_level   = "Information"
    }
    http_logs {
      file_system {
        retention_in_days = 2
        retention_in_mb   = 50
      }
    }
  }  
  # Settings needed for Java Spring app to work
  app_settings = {
    "KEYVAULT_URL"                    = azurerm_key_vault.vault.vault_uri
    "KEYVAULT_TENANT_ID"              = data.azurerm_client_config.current.tenant_id
    "KEYVAULT_CLIENT_ID"              = data.azuread_service_principal.sp.application_id
    "KEYVAULT_CLIENT_KEY"             = var.sp_key 
  }

  identity {
    type                = "SystemAssigned"
  }
  
  depends_on = [azurerm_redis_cache.redis, azurerm_mysql_flexible_server.dbserver]
}

# Create a dev slot in the AppService
resource "azurerm_linux_web_app_slot" "devslot" {
  name           = "devslot"
  app_service_id = azurerm_linux_web_app.backwebapp.id
  site_config {
    minimum_tls_version = "1.2"
    container_registry_use_managed_identity = true
    application_stack {
      docker_image      = "${azurerm_container_registry.acr.login_server}/todoapp"
      docker_image_tag  = "latest"
    }
  }
  
  # Java Spring settings
  app_settings = {
    "KEYVAULT_URL"                    = azurerm_key_vault.vault.vault_uri
    "KEYVAULT_TENANT_ID"              = data.azurerm_client_config.current.tenant_id
    "KEYVAULT_CLIENT_ID"              = data.azuread_service_principal.sp.application_id
    "KEYVAULT_CLIENT_KEY"             = var.sp_key
  }

  identity {
    type  = "SystemAssigned"
  }

}

# DNS Private zone for Privatelink
resource "azurerm_private_dns_zone" "dnsprivatezone" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = local.resource_group 
}

# Link DNS to Vnet
resource "azurerm_private_dns_zone_virtual_network_link" "dnszonelink" {
  name = "dnszonelink"
  resource_group_name = local.resource_group 
  private_dns_zone_name = azurerm_private_dns_zone.dnsprivatezone.name
  virtual_network_id = azurerm_virtual_network.vnet.id
}

# Setup privateendpoint for AppService
resource "azurerm_private_endpoint" "privateendpoint" {
  name                = "${local.prefix}-privateendpoint"
  location            = local.location 
  resource_group_name = local.resource_group 
  subnet_id           = azurerm_subnet.endpointsubnet.id

  private_dns_zone_group {
    name = "privatednszonegroup"
    private_dns_zone_ids = [azurerm_private_dns_zone.dnsprivatezone.id]
  }

  private_service_connection {
    name = "privateendpointconnection"
    private_connection_resource_id = azurerm_linux_web_app.backwebapp.id
    subresource_names = ["sites"]
    is_manual_connection = false
  }
}

# Create a test VM so that we can test our web app
resource "azurerm_network_interface" "win11nic" {
  name                = "win-nic"
  resource_group_name = local.resource_group
  location            = local.location
  ip_configuration {
    name                          = "internal-nic"
    subnet_id                     = azurerm_subnet.endpointsubnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.win11publicip.id
  }
}
resource "azurerm_network_security_group" "nsg" {
  name                = "${local.prefix}-nsg"
  location            = local.location
  resource_group_name = local.resource_group 
    security_rule {
    name                       = "RDP"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "*"
    destination_address_prefix = "*"

  }
}
resource "azurerm_windows_virtual_machine" "win11vm" {
  name                            = "${local.prefix}-vm"
  resource_group_name             = local.resource_group 
  location                        = local.location
  size                            = "Standard_F2s_v2"
  admin_username                  = "vmadmin"
  admin_password                  = "Password123$"
  network_interface_ids = [ azurerm_network_interface.win11nic.id]
  source_image_reference {
    publisher = "microsoftwindowsdesktop"
    offer     = "windows-11"
    sku       = "win11-22h2-pro"
    version   = "latest"
  }
  os_disk {
    name                 = "${local.prefix}-disk"
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }
 identity {
    type   = "SystemAssigned"
  }
}

resource "azurerm_public_ip" "win11publicip" {
  name                = "winvmip"
  resource_group_name = local.resource_group 
  location            = local.location
  allocation_method   = "Dynamic"
}


# Output values for KeyVault to use with Spring App
output "vault_uri" {
  value = azurerm_key_vault.vault.vault_uri 
}

output "sp_id" {
  value = var.sp_id
}

output "sp_tenantid" {
  value = data.azurerm_client_config.current.tenant_id
}

output "sp_subscriptionid" {
  value = data.azurerm_subscription.current.subscription_id
}


