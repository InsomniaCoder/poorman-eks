# Architecture

## Overview

```
                          Internet
                              │
                    ┌─────────▼─────────┐
                    │   Public Subnet    │
                    │                   │
                    │  ┌─────────────┐  │
                    │  │     ALB     │  │
                    │  └──────┬──────┘  │
                    │         │         │
                    │  ┌──────▼──────┐  │
                    │  │  fck-nat    │  │
                    │  │ (t4g.nano)  │  │
                    │  └──────┬──────┘  │
                    └─────────│─────────┘
                              │ (routes outbound traffic)
                    ┌─────────▼─────────┐
                    │   Private Subnet  │
                    │                   │
                    │  ┌─────────────┐  │
                    │  │ System node │  │
                    │  │ t4g.small   │  │
                    │  │ (spot, MNG) │  │
                    │  │             │  │
                    │  │ - Karpenter │  │
                    │  │ - CoreDNS   │  │
                    │  │ - ALB ctrl  │  │
                    │  └─────────────┘  │
                    │                   │
                    │  ┌─────────────┐  │
                    │  │ Spot nodes  │  │
                    │  │ (Karpenter) │  │
                    │  │             │  │
                    │  │ - Workloads │  │
                    │  └─────────────┘  │
                    └───────────────────┘
                         Single AZ
```

## Key decisions

### Single Availability Zone

All resources run in a single AZ. This eliminates cross-AZ data transfer costs ($0.01/GB each way) which silently inflate bills in multi-AZ setups — especially with EKS where control plane, nodes, and load balancers all cross AZ boundaries constantly.

**Tradeoff:** An AZ outage takes down the entire cluster. This is acceptable for non-critical workloads, dev/staging environments, and cost showcases. For production, add a second AZ and budget for ~$20–40/mo in cross-AZ transfer costs.

All workloads are configured with `topologySpreadConstraints` preferring the same AZ to avoid accidental cross-AZ scheduling if the cluster is later expanded.

---

### NAT: fck-nat instead of AWS NAT Gateway

Nodes run in a private subnet and route outbound internet traffic through a [fck-nat](https://github.com/AndrewGuenther/fck-nat) instance rather than an AWS-managed NAT Gateway.

**What fck-nat is:** A pre-built AMI that configures a small EC2 instance as a NAT device using Linux IP masquerading. It runs in an Auto Scaling Group (min: 1) so it self-heals after eviction or hardware failure.

**Why it's cheap:** NAT Gateway's cost is not the underlying compute — it's the managed, HA, multi-AZ service wrapper AWS sells around it. A t4g.nano doing the same IP rewriting job costs almost nothing.

| | fck-nat (spot t4g.nano) | AWS NAT Gateway |
|---|---|---|
| Hourly | ~$0.0016/hr | $0.048/hr |
| Monthly (base) | **~$1–2/mo** | **~$35/mo** |
| Data processing | none | $0.048/GB |
| HA / multi-AZ | no | yes |
| Management | self-managed | fully managed |

#### Throughput and limitations

A `t4g.nano` provides up to **5 Gbps burstable** network throughput. For most small-to-medium clusters this is sufficient. If your workloads sustain high outbound traffic (e.g. large data exports, model inference with big payloads), you can increase the instance size:

| Instance | Max Network | Spot price/mo |
|---|---|---|
| t4g.nano | 5 Gbps (burst) | ~$1–2 |
| t4g.micro | 5 Gbps (burst) | ~$2–3 |
| t4g.small | 5 Gbps (burst) | ~$5 |
| t4g.medium | 5 Gbps (burst) | ~$8 |
| c7g.large | 12.5 Gbps | ~$22 |

#### Spot eviction risk

The fck-nat instance runs on spot, meaning AWS can reclaim it with a 2-minute notice. During the ~1–2 minutes it takes for a replacement to boot and the route table to update, nodes will lose outbound internet access. Requests to AWS services via VPC Endpoints (see below) are unaffected.

**Mitigation:** Use instance type diversification in the ASG (`t4g.nano`, `t4g.micro`, `t4g.small`) to reduce eviction probability. Run fck-nat on-demand (`t4g.nano` at ~$3.5/mo) if a 2-minute blip is unacceptable.

---

### System node: spot t4g.small via managed node group

Karpenter, CoreDNS, and the AWS Load Balancer Controller run on a single `t4g.small` spot instance managed by an **EKS Managed Node Group (MNG)**, not on Fargate and not provisioned by Karpenter.

**Why not Fargate for system pods?**

Fargate bills per pod with a minimum of 0.25 vCPU / 0.5 GB per pod. Running 3–5 system pods on Fargate costs ~$30–40/mo. A `t4g.small` spot node covers all system pods for ~$4–5/mo with headroom.

**Why not let Karpenter manage its own node?**

There is a chicken-and-egg problem: if Karpenter's node gets evicted, Karpenter is gone and nothing can provision a replacement — the cluster hangs until manual intervention. The MNG has its own AWS-native Auto Scaling Group that recovers independently of Karpenter. When the spot node is evicted, the ASG boots a replacement automatically in ~2 minutes without any dependency on Karpenter being alive.

**Why spot is safe here (with a MNG):**

During the ~2 minutes a replacement system node is booting, existing workload pods continue running. Only new pod scheduling is paused (no Karpenter, no CoreDNS for new lookups). For a cost-optimized cluster this is an acceptable tradeoff — on-demand would cost ~$12/mo for the same node, saving only ~$7–8/mo over spot with no meaningful reliability improvement in a single-AZ setup.

---

### Workload nodes: Karpenter-managed spot instances

All application workloads run on spot instances provisioned by Karpenter. Karpenter selects the cheapest available instance type across a broad pool of Graviton (arm64) instance families, maximizing the probability of getting spot capacity and minimizing cost.

Spot instances are ~60–90% cheaper than on-demand. Combined with Graviton's ~20% price-performance advantage over x86, this is the single biggest cost lever in the architecture.

---

### VPC Endpoints (optional, not deployed by default)

Instead of routing AWS API traffic through the fck-nat instance, you can deploy VPC Interface Endpoints to give nodes direct private access to AWS services. This removes AWS service traffic from the NAT path entirely.

| Endpoint | Type | Cost |
|---|---|---|
| S3 | Gateway | **Free** |
| ECR API | Interface | ~$8/mo |
| ECR DKR | Interface | ~$8/mo |
| EC2 | Interface | ~$8/mo |
| STS | Interface | ~$8/mo |
| CloudWatch Logs | Interface | ~$8/mo |
| **Total** | | **~$32–40/mo** |

VPC Endpoints make sense when:
- You want to eliminate the fck-nat spot eviction risk for AWS service calls
- Your workloads pull many large container images (avoiding NAT data processing)
- You are moving toward a zero-internet-access posture

VPC Endpoints do **not** replace fck-nat if your workloads need to reach the public internet (Docker Hub, GitHub, external APIs). In that case both can coexist: AWS traffic goes via endpoints, everything else via fck-nat.

---

## Cost breakdown

Estimates based on `eu-west-1` (Ireland) pricing, single AZ, light workload.

| Component | Type | Est. cost/mo |
|---|---|---|
| EKS control plane | Fixed | $72 |
| fck-nat (t4g.nano spot) | Spot EC2 | ~$1–2 |
| System node (t4g.small spot, MNG) | Spot EC2 | ~$4–5 |
| Workload nodes (Karpenter spot) | Spot EC2 | ~$10–30 (varies) |
| ALB | Load balancer | ~$18 |
| EBS (node root volumes) | Storage | ~$3–5 |
| **Total** | | **~$107–132/mo** |

Replacing fck-nat with AWS NAT Gateway would add ~$35/mo base + data transfer costs. Replacing the spot system node with on-demand would add ~$7–8/mo. Replacing it with Fargate pods would add ~$25–35/mo. None of these changes improve reliability meaningfully in a single-AZ setup.

---

## What this is not

- **Not HA.** A single AZ means a single point of failure at the infrastructure level.
- **Not zero-downtime.** Spot evictions, fck-nat replacement, and Karpenter scale-up all introduce brief interruptions.
- **Not internet-isolated.** Nodes can reach the public internet via fck-nat. For a zero-egress posture, replace fck-nat with VPC Endpoints and restrict outbound in your security groups.
