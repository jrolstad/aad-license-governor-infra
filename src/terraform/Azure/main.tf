terraform {
  required_version = ">=1.0"

  required_providers {
    azurerm = {
      version = "=2.84.0"
      source  = "hashicorp/azurerm"
    }
    azuread = {
      version = "=2.8.0"
      source  = "hashicorp/azuread"
    }
  }
  backend "azurerm" {

  }
}

provider "azurerm" {
  use_msi         = var.use_msi_to_authenticate
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  environment     = var.azure_environment
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

data "azuread_client_config" "current" {

}

locals {
  primary_region                = var.regions[0]
  functions_baseurl             = var.azure_environment == "usgovernment" ? "azurewebsites.us" : "azurewebsites.net"
  api_base_url                  = "${var.service_name}-api-${var.environment}.${local.functions_baseurl}"
  executing_serviceprincipal_id = data.azuread_client_config.current.object_id
  application_owners            = distinct(concat(var.application_owners, [local.executing_serviceprincipal_id]))
}

# Foundation
resource "azurerm_resource_group" "service_resource_group" {
  name     = var.resource_group_name
  location = local.primary_region
}

# Identities
resource "azurerm_user_assigned_identity" "graph_api_managed_identity" {
  name                = "${var.service_name}-graphapi-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
}

resource "azurerm_user_assigned_identity" "keyvault_api_managed_identity" {
  name                = "${var.service_name}-keyvault-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
}

data "azuread_application_published_app_ids" "well_known" {}

resource "azuread_service_principal" "msgraph" {
  application_id = data.azuread_application_published_app_ids.well_known.result.MicrosoftGraph
  use_existing   = true
}

#Directory.Read.All | Required for reading licensed products
resource "azuread_app_role_assignment" "graph_directory_readall" {
  app_role_id         = azuread_service_principal.msgraph.app_role_ids["Directory.Read.All"]
  principal_object_id = azurerm_user_assigned_identity.graph_api_managed_identity.principal_id
  resource_object_id  = azuread_service_principal.msgraph.object_id
}

#Group.ReadWrite.All | Required for reading and writing assigned licenses for groups
resource "azuread_app_role_assignment" "graph_group_readwriteall" {
  app_role_id         = azuread_service_principal.msgraph.app_role_ids["Group.ReadWrite.All"]
  principal_object_id = azurerm_user_assigned_identity.graph_api_managed_identity.principal_id
  resource_object_id  = azuread_service_principal.msgraph.object_id
}

# Key Vault
resource "azurerm_key_vault" "keyvault" {
  name                = "${var.service_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
  sku_name            = "standard"
  tenant_id           = var.tenant_id
}

resource "azurerm_key_vault_access_policy" "executing_owner_access" {
  key_vault_id = azurerm_key_vault.keyvault.id
  tenant_id    = azurerm_key_vault.keyvault.tenant_id
  object_id    = local.executing_serviceprincipal_id

  secret_permissions = ["Get", "Set", "List", "Delete"]
}

resource "azurerm_key_vault_access_policy" "api_access" {
  key_vault_id = azurerm_key_vault.keyvault.id
  tenant_id    = azurerm_key_vault.keyvault.tenant_id
  object_id    = azurerm_user_assigned_identity.keyvault_api_managed_identity.principal_id

  secret_permissions = ["Get"]
}

# Storage
resource "azurerm_storage_account" "storage_account" {
  name                     = "${var.service_name}${var.environment}"
  resource_group_name      = azurerm_resource_group.service_resource_group.name
  location                 = azurerm_resource_group.service_resource_group.location
  account_tier             = "Standard"
  account_replication_type = "GRS"
}

# Logging
resource "azurerm_log_analytics_workspace" "loganalytics" {
  name                = "${var.service_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
  sku                 = "PerGB2018"
}

resource "azurerm_application_insights" "appinsights" {
  name                = "${var.service_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
  workspace_id        = azurerm_log_analytics_workspace.loganalytics.id
  application_type    = "web"
}

# CosmosDb
resource "azurerm_cosmosdb_account" "cosmosaccount" {
  name                = "${var.service_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  geo_location {
    location          = azurerm_resource_group.service_resource_group.location
    failover_priority = 0
  }

  consistency_policy {
    consistency_level = "Session"
  }

  capabilities {
    name = "EnableServerless"
  }

}

resource "azurerm_key_vault_secret" "cosmos_primary_key" {
  key_vault_id = azurerm_key_vault.keyvault.id
  name         = "cosmos-primary-key"
  value        = azurerm_cosmosdb_account.cosmosaccount.primary_key
}

resource "azurerm_cosmosdb_sql_database" "cosmosdb" {
  name                = var.service_name
  resource_group_name = azurerm_cosmosdb_account.cosmosaccount.resource_group_name
  account_name        = azurerm_cosmosdb_account.cosmosaccount.name

}

resource "azurerm_cosmosdb_sql_container" "cosmoscontainer_directories" {
  name                = "Directories"
  resource_group_name = azurerm_cosmosdb_sql_database.cosmosdb.resource_group_name
  account_name        = azurerm_cosmosdb_sql_database.cosmosdb.account_name
  database_name       = azurerm_cosmosdb_sql_database.cosmosdb.name
  partition_key_path  = "/Area"
}

resource "azurerm_cosmosdb_sql_container" "cosmoscontainer_groups" {
  name                = "Groups"
  resource_group_name = azurerm_cosmosdb_sql_database.cosmosdb.resource_group_name
  account_name        = azurerm_cosmosdb_sql_database.cosmosdb.account_name
  database_name       = azurerm_cosmosdb_sql_database.cosmosdb.name
  partition_key_path  = "/TenantId"
}

# Azure Function
resource "random_uuid" "api_user_impersonation_role" {}
resource "random_uuid" "directory_contributor_role" {}
resource "random_uuid" "group_contributor_role" {}
resource "random_uuid" "licensing_contributor_role" {}

resource "azuread_application" "application_api" {
  display_name     = "${var.service_name}-api-${var.environment}"
  owners           = local.application_owners
  sign_in_audience = "AzureADMyOrg"
  identifier_uris  = ["api://${var.service_name}-api-${var.environment}"]
  web {
    redirect_uris = ["https://${local.api_base_url}/.auth/login/aad/callback"]

    implicit_grant {
      access_token_issuance_enabled = true
      id_token_issuance_enabled     = true
    }
  }

  required_resource_access {
    resource_app_id = azuread_service_principal.msgraph.application_id # Microsoft Graph
    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d" # User.Read
      type = "Scope"
    }
  }

  api {
    oauth2_permission_scope {
      admin_consent_description  = "Allow the application to access the API on your behalf"
      admin_consent_display_name = "Access API"
      enabled                    = true
      id                         = random_uuid.api_user_impersonation_role.result
      type                       = "User"
      user_consent_description   = "Allow the application to access the API on your behalf"
      user_consent_display_name  = "Access API"
      value                      = "user_impersonation"
    }
  }

  app_role {
    allowed_member_types = ["User"]
    description          = "Manage Directories"
    display_name         = "Directory Contributor"
    enabled              = true
    id                   = random_uuid.directory_contributor_role.result
    value                = "DirectoryContributor"
  }

  app_role {
    allowed_member_types = ["User"]
    description          = "Manage Groups"
    display_name         = "Group Contributor"
    enabled              = true
    id                   = random_uuid.group_contributor_role.result
    value                = "GroupContributor"
  }

  app_role {
    allowed_member_types = ["User"]
    description          = "Manage Licensing"
    display_name         = "Licensing Contributor"
    enabled              = true
    id                   = random_uuid.licensing_contributor_role.result
    value                = "LicensingContributor"
  }
}

resource "azuread_service_principal" "application_sp_api" {
  application_id               = azuread_application.application_api.application_id
  owners                       = local.application_owners
  description                  = "${var.service_name}-api-${var.environment}"
  app_role_assignment_required = false
}

resource "azurerm_app_service_plan" "function_serviceplan" {
  name                = "${var.service_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
  kind                = "FunctionApp"
  sku {
    tier = "Dynamic"
    size = "Y1"
  }
}

resource "azurerm_function_app" "function_api" {
  name                       = "${var.service_name}-api-${var.environment}"
  resource_group_name        = azurerm_resource_group.service_resource_group.name
  location                   = azurerm_resource_group.service_resource_group.location
  app_service_plan_id        = azurerm_app_service_plan.function_serviceplan.id
  storage_account_name       = azurerm_storage_account.storage_account.name
  storage_account_access_key = azurerm_storage_account.storage_account.primary_access_key
  version                    = "~3"
  https_only                 = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.graph_api_managed_identity.id, azurerm_user_assigned_identity.keyvault_api_managed_identity.id]
  }

  site_config {
    http2_enabled   = true
    ftps_state      = "FtpsOnly"
    min_tls_version = "1.2"
  }

  auth_settings {
    enabled = true
    active_directory {
      client_id = azuread_application.application_api.application_id

      allowed_audiences = ["https://${local.api_base_url}"]
    }

    default_provider              = "AzureActiveDirectory"
    issuer                        = "https://sts.windows.net/${var.tenant_id}"
    token_store_enabled           = true
    unauthenticated_client_action = "AllowAnonymous"

  }

  app_settings = {
    "APPINSIGHTS_INSTRUMENTATIONKEY"        = azurerm_application_insights.appinsights.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.appinsights.connection_string
    "WEBSITE_RUN_FROM_PACKAGE"              = "1"
    "ASPNETCORE_ENVIRONMENT"                = "Release"
    "FUNCTIONS_EXTENSION_VERSION"           = "~3"
    "FUNCTIONS_WORKER_RUNTIME"              = "dotnet-isolated"
    "Cosmos:BaseUri"                        = azurerm_cosmosdb_account.cosmosaccount.endpoint
    "KeyVault:BaseUri"                      = azurerm_key_vault.keyvault.vault_uri
    "KeyVault:ManagedIdentityClientId"      = azurerm_user_assigned_identity.keyvault_api_managed_identity.client_id

  }
}

# Worker
resource "azurerm_function_app" "function_worker" {
  name                       = "${var.service_name}-worker-${var.environment}"
  resource_group_name        = azurerm_resource_group.service_resource_group.name
  location                   = azurerm_resource_group.service_resource_group.location
  app_service_plan_id        = azurerm_app_service_plan.function_serviceplan.id
  storage_account_name       = azurerm_storage_account.storage_account.name
  storage_account_access_key = azurerm_storage_account.storage_account.primary_access_key
  version                    = "~3"
  https_only                 = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.graph_api_managed_identity.id, azurerm_user_assigned_identity.keyvault_api_managed_identity.id]
  }

  site_config {
    http2_enabled   = true
    ftps_state      = "FtpsOnly"
    min_tls_version = "1.2"
  }

  app_settings = {
    "APPINSIGHTS_INSTRUMENTATIONKEY"        = azurerm_application_insights.appinsights.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.appinsights.connection_string
    "WEBSITE_RUN_FROM_PACKAGE"              = "1"
    "ASPNETCORE_ENVIRONMENT"                = "Release"
    "FUNCTIONS_EXTENSION_VERSION"           = "~3"
    "FUNCTIONS_WORKER_RUNTIME"              = "dotnet-isolated"
    "Cosmos:BaseUri"                        = azurerm_cosmosdb_account.cosmosaccount.endpoint
    "KeyVault:BaseUri"                      = azurerm_key_vault.keyvault.vault_uri
    "KeyVault:ManagedIdentityClientId"      = azurerm_user_assigned_identity.keyvault_api_managed_identity.client_id
    "GroupLicenseFunction:ApplyCron"        = "0 0 */10 * * *"

  }
}
