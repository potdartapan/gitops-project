variable "resource_group_name" {
  type        = string
  description = "Name of the resource group"
}

variable "location" {
  type        = string
  description = "Azure region to deploy resources"
}

variable "cluster_name" {
  type        = string
  description = "Name of the AKS cluster"
}

variable "node_count" {
  type        = number
  description = "Number of worker nodes in the cluster"
  default     = 1
}

variable "acr_name_prefix" {
  type        = string
  description = "Prefix for the container registry name"
  default     = "myacr"
}
