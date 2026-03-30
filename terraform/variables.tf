variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "sso-demo-auth-api"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus2"
}

variable "vnet_cidr" {
  description = "VNet address space"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidrs" {
  description = "Subnet CIDR blocks"
  type        = map(string)
  default = {
    appgw = "10.0.1.0/24"
    pe    = "10.0.2.0/24"
    apim  = "10.0.3.0/24"
    agc   = "10.0.4.0/24"
    aks1  = "10.0.16.0/22"
    aks2  = "10.0.20.0/22"
  }
}

variable "aks_node_size" {
  description = "AKS node pool VM size"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "aks_node_count" {
  description = "Number of nodes per AKS cluster"
  type        = number
  default     = 1
}
