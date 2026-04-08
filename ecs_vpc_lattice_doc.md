# AWS ECS Service Discovery with VPC Lattice

**Architecture Design & Implementation Guide**

| Field | Detail |
|---|---|
| Version | 1.0 |
| Classification | Confidential — Internal Use Only |
| Scope | ECS Fargate · VPC Lattice · AWS Certificate Manager |
| Objectives | Service Discovery · Fault Tolerance · Encrypted TLS/mTLS |

---

## 1. Executive Summary

This document provides a comprehensive architecture and implementation guide for deploying AWS ECS-based microservices using AWS VPC Lattice as the service networking layer. The solution addresses three core requirements: automated service discovery, fault-tolerant high-availability design, and encrypted communications using TLS and mutual TLS (mTLS).

AWS VPC Lattice is a fully managed application networking service that abstracts away the complexity of service-to-service communication across ECS tasks, VPCs, and accounts. Combined with ECS service discovery, it provides a production-grade foundation for modern microservice architectures.

**Key requirements addressed:**

1. **Service Discovery** — Automated registration and deregistration of ECS tasks via VPC Lattice target groups and AWS Cloud Map.
2. **Fault Tolerance (HA)** — Multi-AZ ECS deployments, health checks, circuit breakers, and Lattice automatic failover.
3. **Encrypted Communication** — TLS 1.2/1.3 and mTLS with ACM-issued certificates, automated rotation, and SPIFFE/SVID-based workload identity.

---

## 2. Architecture Overview

### 2.1 Component Topology

AWS VPC Lattice is layered on top of ECS Fargate to create a zero-trust, encrypted service mesh without requiring a sidecar proxy or custom infrastructure.

| Component | Role |
|---|---|
| ECS Fargate Cluster | Hosts containerized microservice workloads across multiple AZs |
| AWS VPC Lattice Service Network | Logical boundary connecting all services; enforces auth and TLS policies |
| VPC Lattice Services | Individual named services (e.g., `orders-svc`, `payment-svc`) with DNS-based routing |
| VPC Lattice Target Groups | Backed by ECS tasks (IP-based); auto-registered via EventBridge + Lambda |
| AWS Cloud Map | Provides DNS service discovery for ECS tasks; integrates with Lattice listeners |
| AWS Certificate Manager (ACM) | Issues, stores, and auto-rotates TLS/mTLS certificates for Lattice listeners |
| AWS Private CA (PCA) | Issues private certificates for mTLS workload identity; roots of trust |
| IAM Auth Policy (Lattice) | Resource-based policies on Lattice services enforce mTLS + IAM caller identity |
| AWS EventBridge | Triggers Lambda on ECS task state changes to keep target groups in sync |
| AWS Lambda | Registers/deregisters ECS task IPs in Lattice target groups automatically |

### 2.2 Traffic Flow

The end-to-end request path for service-to-service communication:

1. ECS Task A resolves the VPC Lattice service DNS name (e.g., `orders-svc.vpc-lattice-svcs.us-east-1.on.aws`) via Route 53 Resolver.
2. Traffic is intercepted by the VPC Lattice data plane at the VPC level — no sidecar or agent required.
3. VPC Lattice validates the IAM SigV4 request signature and mTLS client certificate against the service auth policy.
4. VPC Lattice forwards traffic to a healthy ECS task IP registered in the target group, load-balanced across AZs.
5. The response is returned over the same encrypted channel with mutual authentication.

### 2.3 Network Segmentation

VPC Lattice operates at the service network level, not the VPC level:

- Multiple VPCs can share a single Lattice service network (cross-VPC discovery).
- ECS tasks communicate via Lattice overlay addresses (`169.254.171.0/24`) — no VPC peering required.
- Security group rules on ECS tasks must allow **outbound** to `169.254.171.0/24` on port 443 (TLS).
- **Inbound** rules must allow traffic from the Lattice fleet CIDR prefix list (managed by AWS).

---

## 3. Service Discovery

### 3.1 Discovery Mechanisms

Service discovery operates at two complementary layers:

| Layer | Mechanism | Scope |
|---|---|---|
| L4 — Task Registration | EventBridge + Lambda auto-registers ECS task IPs in Lattice target groups | Per ECS Service |
| L7 — Service Addressing | VPC Lattice assigns a stable DNS FQDN per service; tasks resolve via Route 53 | Cross-VPC / Cross-Account |
| Optional: Cloud Map | Tracks tasks at the DNS/API level; can feed Lattice or be used standalone | VPC-local |

### 3.2 Automated Task Registration (EventBridge + Lambda)

ECS tasks are ephemeral — their IPs change on every deployment or failure. The following pattern keeps Lattice target groups synchronized.

**EventBridge rule:**

```json
{
  "source": ["aws.ecs"],
  "detail-type": ["ECS Task State Change"],
  "detail": {
    "clusterArn": ["arn:aws:ecs:REGION:ACCOUNT:cluster/CLUSTER_NAME"],
    "lastStatus": ["RUNNING", "STOPPED"]
  }
}
```

**Lambda handler (Python):**

```python
import boto3, os

lattice = boto3.client('vpc-lattice')
ecs     = boto3.client('ecs')
TG_ARN  = os.environ['LATTICE_TARGET_GROUP_ARN']

def handler(event, context):
    task   = event['detail']
    status = task['lastStatus']
    eni_ip = _get_task_ip(task['attachments'])
    port   = int(os.environ['SERVICE_PORT'])

    if status == 'RUNNING':
        lattice.register_targets(
            targetGroupIdentifier=TG_ARN,
            targets=[{'id': eni_ip, 'port': port}]
        )
    elif status == 'STOPPED':
        lattice.deregister_targets(
            targetGroupIdentifier=TG_ARN,
            targets=[{'id': eni_ip, 'port': port}]
        )
```

### 3.3 VPC Lattice Service Configuration

Each microservice maps to one VPC Lattice service with an HTTPS listener and routing rules:

```hcl
resource "aws_vpclattice_service" "orders" {
  name            = "orders-svc"
  auth_type       = "AWS_IAM"
  certificate_arn = aws_acm_certificate.orders.arn
}

resource "aws_vpclattice_listener" "orders_https" {
  service_identifier = aws_vpclattice_service.orders.id
  protocol           = "HTTPS"
  port               = 443

  default_action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.orders.id
        weight                  = 100
      }
    }
  }
}
```

### 3.4 DNS Resolution

Once a VPC Lattice service is associated with a service network and a VPC, AWS automatically creates a Route 53 private hosted zone entry:

- **Format:** `<service-name>-<id>.vpc-lattice-svcs.<region>.on.aws`
- Resolves to a link-local Lattice address (`169.254.171.x`) — no public DNS exposure.
- ECS tasks call services by their stable FQDN; no hardcoded IPs or sidecars needed.
- Custom domain names can be mapped via Lattice custom domain + Route 53 CNAME.

> **Summary:** ECS task IPs are automatically tracked in VPC Lattice target groups via EventBridge + Lambda. Services are addressed by stable DNS FQDNs. Consumers never need to know individual task IPs — Lattice handles routing transparently.

---

## 4. Fault Tolerance & High Availability

### 4.1 Multi-AZ ECS Deployment

ECS services must be spread across at least three Availability Zones to tolerate AZ-level failures:

```hcl
resource "aws_ecs_service" "orders" {
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.orders.arn
  desired_count   = 6  # 2 tasks per AZ (3 AZs)

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }

  placement_constraints {
    type = "distinctInstance"
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}
```

### 4.2 Health Check Configuration

Two levels of health checking protect availability:

| Level | Mechanism | Action on Failure |
|---|---|---|
| ECS Task (container) | HTTP GET `/health` on container port; 2xx = healthy | ECS replaces unhealthy task; Lambda deregisters old IP |
| Lattice Target Group | HTTP/HTTPS probe on configured path; 200 = healthy | Lattice stops routing to unhealthy target immediately |
| ECS Service Deployment | Circuit breaker monitors rolling update failure rate | Auto-rollback to last known-good task definition |

```hcl
resource "aws_vpclattice_target_group" "orders" {
  name = "orders-tg"
  type = "IP"

  config {
    port           = 8080
    protocol       = "HTTP"
    vpc_identifier = aws_vpc.main.id

    health_check {
      enabled             = true
      path                = "/health"
      protocol            = "HTTP"
      healthy_threshold   = 2
      unhealthy_threshold = 3
      interval_seconds    = 15
      timeout_seconds     = 5
      matcher { value = "200" }
    }
  }
}
```

### 4.3 Weighted Routing & Canary Deployments

VPC Lattice listener rules support weighted target groups natively, enabling zero-downtime canary and blue/green deployments:

```hcl
forward {
  target_groups {
    target_group_identifier = tg_stable.id
    weight                  = 90
  }
  target_groups {
    target_group_identifier = tg_canary.id
    weight                  = 10
  }
}
```

### 4.4 Retry & Timeout Policies

- Automatic retry on 5xx responses (configurable attempts: 1–3).
- Per-request timeout configurable at the Lattice listener (default: 60s).
- ECS service-level connection draining (deregistration delay) ensures in-flight requests complete before task termination.
- Recommended: set ECS `stopTimeout` to 30s to allow graceful shutdown of active connections.

### 4.5 Disaster Recovery Posture

| Failure Scenario | Mitigation |
|---|---|
| Single ECS task crash | Lattice health check removes target; ECS restarts task; Lambda re-registers |
| Availability Zone outage | Lattice redistributes traffic to healthy AZs automatically; ECS replaces tasks |
| Bad deployment (code bug) | ECS deployment circuit breaker detects failure rate and auto-rolls back |
| Lambda registration failure | DLQ on EventBridge rule; CloudWatch alarm; fallback periodic reconciliation Lambda |
| ACM certificate expiry | ACM auto-renewal 60 days before expiry; alert if renewal fails; PCA CRL published |

---

## 5. Encrypted Communication

### 5.1 Encryption Modes: TLS vs mTLS

| Mode | TLS (One-Way) | mTLS (Mutual) |
|---|---|---|
| Who authenticates | Server only (Lattice presents cert) | Server AND client (both present certs) |
| Use case | Public-facing APIs, internal low-sensitivity services | Service-to-service zero-trust, PCI/HIPAA regulated workloads |
| Client cert required | No | Yes — issued per ECS task or per service |
| Configured at | Lattice service listener (ACM cert ARN) | Lattice trust store + ECS task (client cert injection) |
| IAM auth interaction | Works independently of IAM auth | Combine with `auth_type=AWS_IAM` for layered security |

### 5.2 TLS Configuration (One-Way)

```hcl
resource "aws_acm_certificate" "orders" {
  domain_name       = "orders.internal.example.com"
  validation_method = "DNS"
}

resource "aws_vpclattice_service" "orders" {
  certificate_arn = aws_acm_certificate.orders.arn
  auth_type       = "NONE"
}
```

ACM requires domain ownership validation. For private DNS (Route 53 private hosted zones), use DNS validation — ACM generates a CNAME record and monitors it; the certificate issues automatically within minutes. Wildcard certificates (`*.internal.example.com`) cover all Lattice services on the same domain.

### 5.3 mTLS Configuration (Mutual TLS)

mTLS requires every ECS task (client) to present a valid client certificate when connecting to a Lattice service.

**Private CA setup:**

```hcl
resource "aws_acmpca_certificate_authority" "internal" {
  type = "ROOT"

  certificate_authority_configuration {
    key_algorithm     = "RSA_2048"
    signing_algorithm = "SHA256WITHRSA"
    subject {
      organization = "MyOrg"
      common_name  = "MyOrg Internal CA"
    }
  }

  revocation_configuration {
    crl_configuration {
      enabled            = true
      expiration_in_days = 7
      s3_bucket_name     = aws_s3_bucket.crl.bucket
    }
  }
}
```

**Trust store and listener attachment:**

```bash
aws vpc-lattice create-trust-store \
  --name "internal-mtls-trust" \
  --certificate-chain fileb://pca-root-cert.pem

aws vpc-lattice update-listener \
  --service-identifier svc-xxxx \
  --listener-identifier lis-xxxx \
  --mutual-tls-authentication trustStoreArn=arn:aws:...
```

**ECS task client certificate injection (init container):**

```json
{
  "name": "cert-init",
  "image": "amazon/aws-cli",
  "essential": false,
  "command": [
    "sh", "-c",
    "aws secretsmanager get-secret-value --secret-id mtls/orders-cert --query SecretString --output text > /certs/client.pem"
  ],
  "mountPoints": [{"sourceVolume": "certs", "containerPath": "/certs"}]
}
```

The main application container mounts the same volume and reads `/certs/client.pem` and `/certs/client-key.pem` when establishing outbound HTTPS connections.

### 5.4 Certificate Lifecycle

#### Rotation strategies

| Strategy | Details |
|---|---|
| Short-lived certs (recommended) | 24h TTL; init container re-issues on every task start; no rotation infrastructure needed |
| ACM auto-renewal (server certs) | ACM renews 60 days before expiry automatically; Lattice picks up new cert ARN with zero downtime |
| Secrets Manager rotation | Lambda rotation function re-issues PCA cert and updates secret |
| SPIFFE/SPIRE integration | SPIRE agent issues X.509 SVIDs to tasks via Unix socket; 1-hour TTL with automatic in-process rotation |

#### SPIFFE/SPIRE for workload identity (advanced)

| Feature | Benefit |
|---|---|
| Automatic cert rotation | SPIRE agent renews SVIDs every hour in-process; no task restart needed |
| Workload attestation | Attests ECS task identity using IAM role + cluster ARN as attestor |
| SPIFFE ID as service identity | Lattice trust store validates SPIFFE URI SANs in client cert |
| Federation | Can federate with external PKI (HashiCorp Vault, external SPIRE servers) |

#### Certificate revocation

- AWS Private CA publishes a CRL to S3 every 7 days (configurable).
- VPC Lattice does not currently fetch CRLs automatically — rely on short-lived cert TTLs (< 24h) to minimize the revocation window.
- For SPIRE: remove the workload entry from SPIRE Server; all new SVIDs for that workload are denied within one rotation interval (1 hour).
- Emergency revocation: terminate the ECS task immediately; Lattice deregisters the target; the old cert expires within its TTL.

> **Best practice:** Use short-lived certificates (24h or less) issued per ECS task by AWS Private CA. This eliminates the need for explicit revocation infrastructure. Combine with SPIRE for in-process rotation without task restarts.

---

## 6. IAM Authorization Policy

When `auth_type` is set to `AWS_IAM` on a Lattice service, every caller must present a valid SigV4-signed request — a second authorization layer on top of mTLS:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "AWS": [
        "arn:aws:iam::ACCOUNT:role/ecs-task-role-payments",
        "arn:aws:iam::ACCOUNT:role/ecs-task-role-orders"
      ]
    },
    "Action": "vpc-lattice-svcs:Invoke",
    "Resource": "arn:aws:vpc-lattice:REGION:ACCOUNT:service/svc-xxxx/*",
    "Condition": {
      "StringEquals": { "vpc-lattice-svcs:RequestMethod": ["GET", "POST"] }
    }
  }]
}
```

---

## 7. Observability & Monitoring

### 7.1 Key Metrics & Alarms

| Metric | Alarm Threshold |
|---|---|
| `TargetHealthy` count per TG | Alert if < minimum healthy tasks (e.g., < 2 per AZ) |
| Lattice 5xx error rate | Alert if > 1% over 5 minutes; trigger PagerDuty |
| Lattice request latency (p99) | Alert if p99 > 500ms sustained for 3 minutes |
| ACM certificate expiry (days) | Alert if < 45 days remaining; escalate at < 7 days |
| Lambda registration errors | Alert on any DLQ message; reconciliation job auto-recovers |
| ECS task health check failures | CloudWatch Container Insights; alert on sustained failures |

### 7.2 VPC Lattice Access Logs

Enable Lattice access logs to CloudWatch Logs or S3 for full request/response visibility including TLS metadata:

```hcl
resource "aws_vpclattice_access_log_subscription" "orders" {
  resource_identifier = aws_vpclattice_service.orders.id
  destination_arn     = aws_cloudwatch_log_group.lattice.arn
}
```

Access logs include: caller IAM ARN, client certificate subject/SAN, request path, response code, latency, and target IP. Use these for security audit trails and troubleshooting mTLS failures.

---

## 8. Implementation Checklist

| # | Task |
|---|---|
| 1 | Create VPC Lattice Service Network and associate target VPCs |
| 2 | Deploy AWS Private CA (Root + optionally Subordinate CA) |
| 3 | Request ACM certificates for each Lattice service (DNS validation) |
| 4 | Create VPC Lattice services, HTTPS listeners, and IP-based target groups |
| 5 | Deploy ECS Fargate cluster with multi-AZ capacity provider strategy |
| 6 | Create ECS Task IAM Roles with least-privilege PCA and Secrets Manager permissions |
| 7 | Implement EventBridge rule + Lambda for task IP auto-registration |
| 8 | Add health check endpoint (`/health`) to each ECS containerized service |
| 9 | Configure ECS task definition with `cert-init` container for mTLS |
| 10 | Create Lattice trust store with PCA root certificate chain |
| 11 | Configure IAM auth policy on each Lattice service |
| 12 | Set up CloudWatch alarms for cert expiry, Lattice errors, and Lambda failures |
| 13 | Enable Lattice access logs to CloudWatch Logs for audit trail |
| 14 | Test mTLS with `curl --cert` / `--key` flags against Lattice service FQDN |
| 15 | Chaos test: terminate tasks, fail AZs, revoke certs — validate auto-recovery |

---

## 9. Security Considerations

**Principle of least privilege.** ECS task IAM roles should have access only to their own PCA certificate template, Secrets Manager secrets, and Lattice service ARNs.

**No public exposure.** VPC Lattice services in this architecture use private DNS only. Ensure no public-facing Lattice service network is created.

**Private key protection.** Store private keys in Secrets Manager with KMS encryption. Use ephemeral in-memory volumes (`tmpfs`) on ECS tasks — never persist private keys to EBS or EFS.

**CRL publication.** The PCA CRL S3 bucket should be private with a Lattice/application-facing bucket policy. Block all public access.

**Certificate pinning.** For high-security workloads, implement certificate pinning in the application layer (validate server cert fingerprint) in addition to Lattice validation.

**Audit logging.** CloudTrail records all ACM PCA `IssueCertificate` and Lattice API calls. Enable CloudTrail in all regions.

**CA key rotation.** Annually rotate the Private CA signing key pair using PCA key rotation to limit blast radius of CA compromise.

---

## Appendix A: Reference Architecture

```
[Consumer ECS Task]
    |
    | HTTPS (mTLS, SigV4)
    v
[VPC Lattice Service Network]
    |
    |-- [Lattice Service: orders-svc]
    |       |-- Listener: HTTPS:443
    |       |-- Trust Store: internal-mtls-trust (PCA root cert)
    |       |-- Auth Policy: IAM (ecs-task-role-payments)
    |       |-- Target Group: orders-tg (IP type)
    |               |-- [ECS Task IP AZ-a :8080] (healthy)
    |               |-- [ECS Task IP AZ-b :8080] (healthy)
    |               |-- [ECS Task IP AZ-c :8080] (healthy)
    |
    |-- [Lattice Service: payments-svc]
            |-- ...

[EventBridge Rule] --> [Lambda: register/deregister]
                              |
                              v
                     [Lattice Target Group]

[AWS Private CA] --> issues certs --> [Secrets Manager]
                                          |
                                          v
                              [ECS init container] --> [tmpfs /certs]
```

---

*Document version 1.0 — Internal use only*
