variable "use_msi_to_authenticate" {
  description = "Use a managed service identity to authenticate"
  type        = bool
  default     = false
}

variable "azure_environment" {
  description = "Which Azure Environment being used"
  type        = string
  default     = "public"
}

variable "tenant_id" {
  description = "Azure AD Tenant Id the resources are associated with"
  type        = string
}

variable "subscription_id" {
  description = "Azure Subscription the resources managed in"
  type        = string
}

variable "resource_group_name" {
  description = "Specific resource group to deploy resources into.  If not supplied, will default to servicename-environmentname"
  type        = string
  default     = null
}

variable "service_name" {
  description = "Name of the service"
  type        = string
}

variable "environment" {
  description = "What type of environment (dev,tst,uat,prd)"
  type        = string
}

variable "regions" {
  description = "Azure regions to deploy resources to"
  type        = list(string)
  validation {
    condition     = length(var.regions) > 0
    error_message = "At least 1 region must be defined."
  }
}

variable "application_owners" {
  description = "Owners of the Applications"
  type        = list(string)
  validation {
    condition     = length(var.application_owners) > 0
    error_message = "At least 1 owner must be defined."
  }
}


