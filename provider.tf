terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.5"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(local.common_tags, var.additional_tags)
  }
}

locals {
  name_prefix            = "${var.project_name}-${var.environment}"
  dashboard_port         = try(var.services["dashboard"].container_port, 80)
  dashboard_health_path  = try(var.services["dashboard"].health_path, "/")
  counting_port          = try(var.services["counting"].container_port, 80)
  counting_cloudmap_url  = "http://counting.${aws_service_discovery_private_dns_namespace.main.name}:${local.counting_port}"
  counting_lattice_url   = try("https://${aws_vpclattice_service.services["counting"].dns_entry[0].domain_name}", null)
  dashboard_counting_url = var.dashboard_to_counting_mode == "lattice_https" ? local.counting_lattice_url : local.counting_cloudmap_url

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
