# poorman-eks

Reusable Terraform infrastructure-as-code for provisioning a cost-minimized EKS cluster on AWS.

This is not a production-grade, enterprise reference architecture. It is an opinionated setup for teams and individuals who need a real Kubernetes cluster without paying full AWS price — accepting specific reliability tradeoffs in exchange for dramatically lower costs.

## Design goals

- Minimize monthly AWS bill without sacrificing usability
- Reusable and composable Terraform modules
- Documented tradeoffs for every cost-cutting decision

## Non-goals

- High availability across multiple Availability Zones
- Zero-downtime NAT / network path resilience
- Compliance-ready configurations (HIPAA, PCI, etc.)

## Architecture

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the full design, cost breakdown, and risk analysis.

## Prerequisites

- Terraform >= 1.5
- AWS CLI configured with sufficient IAM permissions
- `kubectl`

## Usage

> Coming soon.

## Cost estimate

> ~$107–132/mo for a minimal working cluster (eu-west-1). See [ARCHITECTURE.md](./ARCHITECTURE.md) for a full breakdown.
