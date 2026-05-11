# Architecture

## Overview

```
                          Internet
                              │
                    ┌─────────▼─────────┐
                    │   Public Subnet    │
                    │                   │
                    │  ┌─────────────┐  │
                    │  │     NLB     │  │
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
                    │  │ - Traefik   │  │
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

## Principles

### Graviton first

All EC2 instances in this architecture use AWS Graviton (arm64) by default. Graviton instances offer the best price-to-performance ratio in every instance family — typically 20% cheaper than equivalent x86 instances at the same or better performance.

This applies to every layer: the fck-nat instance, the system managed node group, and all Karpenter-provisioned workload nodes. Any instance type added to this setup should default to a Graviton variant (`t4g`, `m7g`, `c7g`, `r7g`, etc.) unless there is a specific workload requirement that x86 cannot be avoided.

The only common reason to allow x86 is third-party software that does not publish arm64 container images. In that case, use a mixed `nodeSelector` or `nodeAffinity` to pin only those workloads to x86 nodes, keeping everything else on Graviton.

---

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

### System node: spot 2 vCPU / 4 GB via managed node group

Karpenter, CoreDNS, and Traefik run on a single spot node managed by an **EKS Managed Node Group (MNG)**, not on Fargate and not provisioned by Karpenter.

The MNG uses a pool of **2 vCPU / 4 GB arm64** instance types. EKS MNG requires all instances in the pool to have identical vCPU and RAM so Kubernetes scheduling remains predictable — a pod's resource requests are evaluated against a consistent node capacity.

| Instance | vCPU | RAM | Notes |
|---|---|---|---|
| `t4g.medium` | 2 | 4 GB | Graviton2 burstable, baseline |
| `c6g.large` | 2 | 4 GB | Graviton2 compute-optimised |
| `c7g.large` | 2 | 4 GB | Graviton3 compute-optimised |

Three types in the pool significantly reduces eviction probability vs a single type. The 4 GB RAM (vs 2 GB on t4g.small) provides headroom for Karpenter + CoreDNS + Traefik co-located on the same node without OOM risk.

**Why not Fargate for system pods?**

Fargate bills per pod with a minimum of 0.25 vCPU / 0.5 GB per pod. Running 3–5 system pods on Fargate costs ~$30–40/mo. A spot node from this pool covers all system pods for ~$5–8/mo.

**Why not let Karpenter manage its own node?**

There is a chicken-and-egg problem: if Karpenter's node gets evicted, Karpenter is gone and nothing can provision a replacement — the cluster hangs until manual intervention. The MNG has its own AWS-native Auto Scaling Group that recovers independently of Karpenter. When the spot node is evicted, the ASG boots a replacement automatically in ~2 minutes without any dependency on Karpenter being alive.

**Why spot is safe here (with a MNG):**

During the ~2 minutes a replacement system node is booting, existing workload pods continue running. Only new pod scheduling is paused (no Karpenter, no CoreDNS for new lookups). For a cost-optimized cluster this is an acceptable tradeoff — on-demand t4g.medium would cost ~$15/mo, saving only ~$7–10/mo over spot with no meaningful reliability improvement in a single-AZ setup.

---

### Workload nodes: Karpenter-managed spot instances

All application workloads run on spot instances provisioned by Karpenter. Karpenter selects the cheapest available instance type across a broad pool of Graviton (arm64) instance families, maximizing the probability of getting spot capacity and minimizing cost.

Spot instances are ~60–90% cheaper than on-demand. Combined with Graviton's ~20% price-performance advantage over x86, this is the single biggest cost lever in the architecture.

---

### Ingress: Traefik + single NLB

Rather than using the AWS Load Balancer Controller with per-Ingress ALBs, all HTTP/HTTPS traffic enters the cluster through a single **AWS Network Load Balancer** pointing to **Traefik** running as a DaemonSet (or Deployment) on the system node.

```
Internet → NLB (L4) → Traefik pod (L7) → Services
```

**Why not ALB?**

An ALB costs ~$18/mo minimum per load balancer. The AWS Load Balancer Controller provisions one ALB per `Ingress` resource by default — three services means three ALBs means ~$54/mo in load balancers alone. Sharing via `IngressGroup` helps but still has an ~$18/mo floor.

**Why NLB + Traefik?**

An NLB costs ~$10/mo minimum (cheaper than ALB) and is a single fixed entry point regardless of how many services or routes you add. Traefik handles all L7 routing — host-based routing, path-based routing, TLS termination, middleware — entirely inside the cluster. Adding a new service costs $0 in AWS infrastructure.

**Why Traefik over Nginx?**

Both work. Traefik has better Kubernetes-native integration via `IngressRoute` CRDs, built-in Let's Encrypt support, and a useful dashboard. For a cost-showcase repo it also demonstrates that the ingress layer can be entirely self-managed without AWS-specific controllers.

**Cost comparison:**

| Approach | LB cost/mo | Scales with services? |
|---|---|---|
| ALB per Ingress (default) | ~$18 per service | Yes — gets expensive fast |
| ALB with IngressGroup | ~$18 flat | No |
| **NLB + Traefik** | **~$10 flat** | **No — one NLB always** |

**Traefik on the system node:**

Traefik runs on the system MNG node alongside Karpenter and CoreDNS. It is a lightweight process and fits comfortably within the `t4g.small` resource budget. This means Traefik has the same self-healing behaviour as the rest of the system node — if the spot node is evicted, the MNG ASG replaces it in ~2 minutes and Traefik comes back automatically.

---

### VPC Endpoints

#### S3 Gateway endpoint (enabled by default)

The S3 Gateway endpoint is always enabled. It is free, requires no interface ENI, and routes all S3 traffic (including ECR image layer storage) directly within the AWS network without touching fck-nat. There is no reason not to enable it.

#### Interface endpoints (optional, disabled by default)

Additional VPC Interface Endpoints for ECR, STS, EC2, and CloudWatch can be enabled via the `enable_vpc_endpoints` flag. Each endpoint costs a fixed ~$8/mo in eu-west-1 ($0.011/hr per AZ), regardless of traffic volume.

> **Important:** Unlike AWS NAT Gateway, fck-nat does **not** charge per-GB processed. The cost of routing AWS API traffic through fck-nat is zero beyond the instance cost itself. Interface endpoints therefore do not reduce your bill — they trade a fixed monthly cost for two specific benefits: reliability (AWS service calls survive a fck-nat eviction) and bandwidth headroom (ECR image pulls no longer compete with other outbound traffic on the t4g.nano).

**When interface endpoints are worth it:**

| Scenario | Verdict |
|---|---|
| Low image pull frequency, occasional deploys | Not worth it — fck-nat handles it fine |
| High churn workloads (many pods starting/stopping, large images) | Worth it for ECR — relieves fck-nat bandwidth |
| fck-nat running on-demand (eviction not a concern) | Not worth it for reliability, only for bandwidth |
| Zero-egress security posture required | Worth it — enables full internet lockdown |

**Cost breakdown if enabled:**

| Endpoint | Type | Cost/mo |
|---|---|---|
| S3 | Gateway | **Free** (always on) |
| ECR API | Interface | ~$8 |
| ECR DKR | Interface | ~$8 |
| EC2 | Interface | ~$8 |
| STS | Interface | ~$8 |
| CloudWatch Logs | Interface | ~$8 |
| **All endpoints total** | | **~$40/mo** |

**Bandwidth comparison — fck-nat vs endpoint for ECR:**

A t4g.nano sustains ~600 Mbps real-world throughput for NAT workloads despite the 5 Gbps headline. A cluster pulling many large images simultaneously (e.g. a rollout restarting 20 pods with 2 GB images each) can saturate this. An ECR Interface Endpoint removes image pull traffic from the fck-nat path entirely, leaving full fck-nat capacity for public internet traffic.

If this is a concern, upgrading fck-nat to a `t4g.small` (~$5/mo spot) is cheaper than adding the two ECR endpoints (~$16/mo) unless you also need the reliability benefit.

Interface endpoints do **not** replace fck-nat for public internet access (Docker Hub, GitHub, external APIs). Both can coexist: AWS service traffic routes via endpoints, everything else via fck-nat.

---

## Cost breakdown

Estimates based on `eu-west-1` (Ireland) pricing, single AZ, light workload.

| Component | Type | Est. cost/mo |
|---|---|---|
| EKS control plane | Fixed | $72 |
| fck-nat (t4g.nano spot) | Spot EC2 | ~$1–2 |
| System node (2vCPU/4GB spot, MNG) | Spot EC2 | ~$5–8 |
| Workload nodes (Karpenter spot) | Spot EC2 | ~$10–30 (varies) |
| NLB (Traefik frontend) | Load balancer | ~$10 |
| EBS (node root volumes) | Storage | ~$3–5 |
| S3 Gateway endpoint | VPC Endpoint | Free |
| **Total** | | **~$101–128/mo** |

Optional additions:

| Addition | Extra cost/mo | When to consider |
|---|---|---|
| All interface endpoints | +~$40 | High image churn or zero-egress posture |
| ECR endpoints only | +~$16 | Saturating fck-nat bandwidth on image pulls |
| Upgrade fck-nat to t4g.small | +~$3 | Cheaper alternative to ECR endpoints for bandwidth |
| NAT Gateway instead of fck-nat | +~$35 base + data | Fully managed NAT, no eviction risk |
| System node on-demand (t4g.medium) | +~$7–10 | Eliminate system node spot eviction risk |

---

## What this is not

- **Not HA.** A single AZ means a single point of failure at the infrastructure level.
- **Not zero-downtime.** Spot evictions, fck-nat replacement, and Karpenter scale-up all introduce brief interruptions.
- **Not internet-isolated.** Nodes can reach the public internet via fck-nat. For a zero-egress posture, replace fck-nat with VPC Endpoints and restrict outbound in your security groups.
