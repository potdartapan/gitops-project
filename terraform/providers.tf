terraform {
  required_version = ">= 1.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "gitops-project-tfstate-rg"       # <--- The NEW separate RG
    storage_account_name = "tfstate1769048995"
    container_name       = "tfstate"
    key                  = "terraform.tfstate"
  }
}



provider "azurerm" {
  features {}
}




