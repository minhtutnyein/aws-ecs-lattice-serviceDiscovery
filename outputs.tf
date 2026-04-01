output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "cloud_map_namespace" {
  description = "Cloud Map namespace"
  value       = aws_service_discovery_private_dns_namespace.main.name
}

output "cloud_map_service_names" {
  description = "Cloud Map service names"
  value       = keys(aws_service_discovery_service.services)
}

output "vpc_lattice_service_network_id" {
  description = "VPC Lattice service network ID"
  value       = aws_vpclattice_service_network.main.id
}

output "dashboard_public_url" {
  description = "Public dashboard URL (if ALB is enabled)"
  value       = var.enable_public_dashboard ? "http://${aws_lb.dashboard[0].dns_name}" : null
}

output "dashboard_public_https_url" {
  description = "Public dashboard HTTPS URL (if ACM cert is configured)"
  value       = var.enable_public_dashboard && var.dashboard_alb_certificate_arn != "" ? "https://${aws_lb.dashboard[0].dns_name}" : null
}

output "vpc_lattice_service_dns" {
  description = "VPC Lattice DNS names for each service"
  value       = { for k, v in aws_vpclattice_service.services : k => v.dns_entry[0].domain_name }
}

output "private_ca_arn" {
  description = "Private CA ARN (if enabled)"
  value       = try(aws_acmpca_certificate_authority.main[0].arn, null)
}

output "service_certificate_arns" {
  description = "Service certificate ARNs (if private CA enabled)"
  value       = { for k, v in aws_acm_certificate.service : k => v.arn }
}

output "lattice_auth_policy_ids" {
  description = "VPC Lattice auth policy IDs by service"
  value       = { for k, v in aws_vpclattice_auth_policy.services : k => v.id }
}

output "eventbridge_lambda_reconciler_name" {
  description = "Lambda function name for Lattice target reconciliation when enabled"
  value       = try(aws_lambda_function.lattice_target_reconciler[0].function_name, null)
}

output "workload_mtls_secret_arns" {
  description = "Secrets Manager ARNs containing workload mTLS bundles"
  value       = { for k, v in aws_secretsmanager_secret.workload_mtls_bundle : k => v.arn }
}
