resource "aws_acmpca_certificate_authority" "main" {
  count = var.create_private_ca ? 1 : 0

  type = "ROOT"

  certificate_authority_configuration {
    key_algorithm     = "RSA_2048"
    signing_algorithm = "SHA256WITHRSA"

    subject {
      common_name         = "${local.name_prefix}-internal-ca"
      organization        = "Platform"
      organizational_unit = "Security"
      country             = "SG"
    }
  }

  permanent_deletion_time_in_days = 7

  tags = {
    Name = "${local.name_prefix}-private-ca"
  }
}

resource "aws_acmpca_certificate" "ca_cert" {
  count = var.create_private_ca ? 1 : 0

  certificate_authority_arn   = aws_acmpca_certificate_authority.main[0].arn
  certificate_signing_request = aws_acmpca_certificate_authority.main[0].certificate_signing_request
  signing_algorithm           = "SHA256WITHRSA"
  template_arn                = "arn:aws:acm-pca:::template/RootCACertificate/V1"

  validity {
    type  = "YEARS"
    value = 5
  }
}

resource "aws_acmpca_certificate_authority_certificate" "ca_cert" {
  count = var.create_private_ca ? 1 : 0

  certificate_authority_arn = aws_acmpca_certificate_authority.main[0].arn
  certificate               = aws_acmpca_certificate.ca_cert[0].certificate
  certificate_chain         = aws_acmpca_certificate.ca_cert[0].certificate_chain
}

resource "aws_acm_certificate" "service" {
  for_each = var.create_private_ca ? var.services : {}

  domain_name               = "${each.key}.${aws_service_discovery_private_dns_namespace.main.name}"
  certificate_authority_arn = aws_acmpca_certificate_authority.main[0].arn

  options {
    certificate_transparency_logging_preference = "DISABLED"
  }

  tags = {
    Name = "${local.name_prefix}-${each.key}-cert"
  }
}

resource "tls_private_key" "workload" {
  for_each = var.create_private_ca && var.enable_workload_mtls_bundle ? var.services : {}

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "workload" {
  for_each = var.create_private_ca && var.enable_workload_mtls_bundle ? var.services : {}

  private_key_pem = tls_private_key.workload[each.key].private_key_pem

  subject {
    common_name         = "${each.key}.${aws_service_discovery_private_dns_namespace.main.name}"
    organization        = "Platform"
    organizational_unit = "App"
    country             = "SG"
  }

  dns_names = [
    each.key,
    "${each.key}.${aws_service_discovery_private_dns_namespace.main.name}"
  ]
}

resource "aws_acmpca_certificate" "workload" {
  for_each = var.create_private_ca && var.enable_workload_mtls_bundle ? var.services : {}

  certificate_authority_arn   = aws_acmpca_certificate_authority.main[0].arn
  certificate_signing_request = tls_cert_request.workload[each.key].cert_request_pem
  signing_algorithm           = "SHA256WITHRSA"
  template_arn                = "arn:aws:acm-pca:::template/EndEntityCertificate/V1"

  validity {
    type  = "DAYS"
    value = var.certificate_validity_days
  }

  depends_on = [aws_acmpca_certificate_authority_certificate.ca_cert]
}

resource "aws_secretsmanager_secret" "workload_mtls_bundle" {
  for_each = var.create_private_ca && var.enable_workload_mtls_bundle ? var.services : {}

  name                    = "/ecs/mtls/${local.name_prefix}/${each.key}"
  description             = "mTLS certificate bundle for ${each.key}"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "workload_mtls_bundle" {
  for_each = var.create_private_ca && var.enable_workload_mtls_bundle ? var.services : {}

  secret_id = aws_secretsmanager_secret.workload_mtls_bundle[each.key].id
  secret_string = jsonencode({
    service_name = each.key
    cert_pem     = aws_acmpca_certificate.workload[each.key].certificate
    key_pem      = tls_private_key.workload[each.key].private_key_pem
    ca_pem       = aws_acmpca_certificate.ca_cert[0].certificate
  })
}
