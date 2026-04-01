variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Project name used in resource naming"
  type        = string
  default     = "ecs-lattice"
}

variable "environment" {
  description = "Environment name (dev/staging/prod)"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.30.0.0/16"
}

variable "availability_zones" {
  description = "AZs used for HA deployment"
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs (one per AZ)"
  type        = list(string)
  default     = ["10.30.1.0/24", "10.30.2.0/24", "10.30.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs (one per AZ)"
  type        = list(string)
  default     = ["10.30.11.0/24", "10.30.12.0/24", "10.30.13.0/24"]
}

variable "enable_nat_gateway" {
  description = "Enable outbound internet for private subnets"
  type        = bool
  default     = true
}

variable "nat_gateway_per_az" {
  description = "Create one NAT gateway per AZ for stronger HA"
  type        = bool
  default     = false
}

variable "ecs_cluster_name" {
  description = "ECS cluster name"
  type        = string
  default     = "ecs-lattice-cluster"
}

variable "log_retention_days" {
  description = "CloudWatch log retention"
  type        = number
  default     = 14
}

variable "vpc_lattice_auth_type" {
  description = "Auth type for VPC Lattice services"
  type        = string
  default     = "AWS_IAM"

  validation {
    condition     = contains(["NONE", "AWS_IAM"], var.vpc_lattice_auth_type)
    error_message = "vpc_lattice_auth_type must be NONE or AWS_IAM"
  }
}

variable "enable_lattice_auth_policy" {
  description = "Attach explicit resource-based IAM auth policy to VPC Lattice services"
  type        = bool
  default     = true
}

variable "allowed_lattice_invoke_principal_arns" {
  description = "Additional IAM principal ARNs allowed to invoke VPC Lattice services"
  type        = list(string)
  default     = []
}

variable "lattice_listener_protocol" {
  description = "Protocol for VPC Lattice listeners"
  type        = string
  default     = "HTTPS"

  validation {
    condition     = contains(["HTTP", "HTTPS"], var.lattice_listener_protocol)
    error_message = "lattice_listener_protocol must be HTTP or HTTPS"
  }
}

variable "lattice_listener_port" {
  description = "Port for VPC Lattice listeners"
  type        = number
  default     = 443
}

variable "enable_lattice_access_logs" {
  description = "Enable VPC Lattice access logs to CloudWatch"
  type        = bool
  default     = false
}

variable "enable_public_dashboard" {
  description = "Expose dashboard service via internet-facing ALB"
  type        = bool
  default     = true
}

variable "public_dashboard_listener_port" {
  description = "Public listener port for dashboard ALB"
  type        = number
  default     = 80
}

variable "public_dashboard_https_port" {
  description = "HTTPS listener port for dashboard ALB"
  type        = number
  default     = 443
}

variable "dashboard_alb_certificate_arn" {
  description = "ACM certificate ARN used by public dashboard ALB HTTPS listener"
  type        = string
  default     = ""
}

variable "redirect_http_to_https" {
  description = "Redirect HTTP requests on ALB to HTTPS when certificate ARN is configured"
  type        = bool
  default     = true
}

variable "create_private_ca" {
  description = "Create ACM Private CA for mTLS cert issuance"
  type        = bool
  default     = false
}

variable "enable_workload_mtls_bundle" {
  description = "Generate workload certificate bundles in Secrets Manager for app-level mTLS integration"
  type        = bool
  default     = false
}

variable "certificate_validity_days" {
  description = "Service certificate validity in days"
  type        = number
  default     = 365
}

variable "dashboard_to_counting_mode" {
  description = "How dashboard resolves counting: cloudmap_http or lattice_https"
  type        = string
  default     = "lattice_https"

  validation {
    condition     = contains(["cloudmap_http", "lattice_https"], var.dashboard_to_counting_mode)
    error_message = "dashboard_to_counting_mode must be cloudmap_http or lattice_https"
  }
}

variable "enable_eventbridge_lambda_reconciler" {
  description = "Enable EventBridge plus Lambda reconciler for Lattice target registration fallback"
  type        = bool
  default     = false
}

variable "services" {
  description = "Microservices deployed to ECS and exposed via Lattice"
  type = map(object({
    image            = string
    container_port   = number
    desired_count    = number
    cpu              = number
    memory           = number
    health_path      = string
    environment_vars = optional(map(string), {})
  }))

  default = {
    counting = {
      image          = "public.ecr.aws/nginx/nginx:stable"
      container_port = 80
      desired_count  = 2
      cpu            = 256
      memory         = 512
      health_path    = "/"
    }
    dashboard = {
      image          = "public.ecr.aws/nginx/nginx:stable"
      container_port = 80
      desired_count  = 2
      cpu            = 256
      memory         = 512
      health_path    = "/"
    }
  }
}

variable "additional_tags" {
  description = "Additional tags merged into all resources"
  type        = map(string)
  default     = {}
}
