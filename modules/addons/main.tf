# ── Karpenter controller IAM role (IRSA) ─────────────────────────────────────

data "aws_iam_policy_document" "karpenter_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:karpenter"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name_prefix        = "karpenter-controller-"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume_role.json
}

resource "aws_iam_role_policy" "karpenter_controller" {
  role = aws_iam_role.karpenter_controller.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowScopedEC2InstanceActions"
        Effect = "Allow"
        Action = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
        Resource = [
          "arn:aws:ec2:*:*:image/*",
          "arn:aws:ec2:*:*:snapshot/*",
          "arn:aws:ec2:*:*:spot-instances-request/*",
          "arn:aws:ec2:*:*:security-group/*",
          "arn:aws:ec2:*:*:subnet/*",
          "arn:aws:ec2:*:*:launch-template/*",
          "arn:aws:ec2:*:*:network-interface/*",
          "arn:aws:ec2:*:*:instance/*",
          "arn:aws:ec2:*:*:fleet/*",
          "arn:aws:ec2:*:*:volume/*",
        ]
      },
      {
        Sid    = "AllowEC2ReadActions"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "AllowEC2MutateActions"
        Effect = "Allow"
        Action = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate", "ec2:CreateTags"]
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid      = "AllowPassNodeIAMRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [var.node_iam_role_arn]
      },
      {
        Sid      = "AllowSQS"
        Effect   = "Allow"
        Action   = ["sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
        Resource = [aws_sqs_queue.karpenter_interruption.arn]
      },
      {
        Sid      = "AllowPricingRead"
        Effect   = "Allow"
        Action   = ["pricing:GetProducts"]
        Resource = ["*"]
      },
    ]
  })
}

# ── SQS + EventBridge for spot interruption ───────────────────────────────────

resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter_interruption.arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "karpenter_interruption" {
  for_each = {
    spot_interruption = { detail_type = ["EC2 Spot Instance Interruption Warning"] }
    rebalance         = { detail_type = ["EC2 Instance Rebalance Recommendation"] }
    instance_state    = { detail_type = ["EC2 Instance State-change Notification"] }
  }

  name          = "${var.cluster_name}-karpenter-${each.key}"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = each.value.detail_type
  })
}

resource "aws_cloudwatch_event_target" "karpenter_interruption" {
  for_each  = aws_cloudwatch_event_rule.karpenter_interruption
  rule      = each.value.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# ── Karpenter Helm ────────────────────────────────────────────────────────────

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.4.0"
  namespace  = "kube-system"

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.karpenter_interruption.name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller.arn
  }
  set {
    name  = "nodeSelector.role"
    value = "system"
  }
  set {
    name  = "tolerations[0].key"
    value = "CriticalAddonsOnly"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
}

# ── Karpenter EC2NodeClass + NodePool ─────────────────────────────────────────

resource "kubernetes_manifest" "ec2_node_class" {
  manifest = {
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      amiFamily = "AL2023"
      role      = var.node_iam_role_name
      subnetSelectorTerms        = [{ tags = { "karpenter.sh/discovery" = var.cluster_name } }]
      securityGroupSelectorTerms = [{ tags = { "karpenter.sh/discovery" = var.cluster_name } }]
      amiSelectorTerms           = [{ alias = "al2023@latest" }]
      metadataOptions            = { httpTokens = "required" }
      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = {
          volumeSize          = "20Gi"
          volumeType          = "gp3"
          deleteOnTermination = true
        }
      }]
    }
  }
  depends_on = [helm_release.karpenter]
}

resource "kubernetes_manifest" "node_pool" {
  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "default" }
    spec = {
      template = {
        spec = {
          requirements = [
            { key = "karpenter.sh/capacity-type",          operator = "In",    values = ["spot"] },
            { key = "kubernetes.io/arch",                  operator = "In",    values = ["arm64"] },
            { key = "topology.kubernetes.io/zone",         operator = "In",    values = ["eu-west-1a"] },
            { key = "karpenter.k8s.aws/instance-family",   operator = "In",    values = ["t4g", "m7g", "c7g", "r7g"] },
            { key = "karpenter.k8s.aws/instance-size",     operator = "NotIn", values = ["nano", "micro"] },
          ]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          expireAfter = "720h"
        }
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
      limits = {
        cpu    = "100"
        memory = "400Gi"
      }
    }
  }
  depends_on = [kubernetes_manifest.ec2_node_class]
}

# ── Gateway API CRDs ──────────────────────────────────────────────────────────

# Applied via null_resource + kubectl because the bundle is a multi-document YAML
# with ~20 CRD resources — managing them individually as kubernetes_manifest would
# be brittle. --server-side avoids annotation size limits on large CRDs.
resource "null_resource" "gateway_api_crds" {
  provisioner "local-exec" {
    command = "kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml --server-side"
  }
}

# ── Traefik v3 ────────────────────────────────────────────────────────────────

resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://helm.traefik.io/traefik"
  chart            = "traefik"
  version          = "33.2.1"
  namespace        = "traefik"
  create_namespace = true

  values = [yamlencode({
    deployment = { replicas = 1 }
    tolerations = [{
      key      = "CriticalAddonsOnly"
      operator = "Exists"
      effect   = "NoSchedule"
    }]
    nodeSelector = { role = "system" }
    service = {
      type = "LoadBalancer"
      annotations = {
        "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
        "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
        "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
      }
    }
    providers = {
      kubernetesGateway = { enabled = true }
      kubernetesIngress = { enabled = false }
    }
    gateway = {
      enabled   = true
      name      = "traefik-gateway"
      namespace = "traefik"
    }
    ports = {
      web       = { port = 8000, expose = { default = true } }
      websecure = { port = 8443, expose = { default = true } }
    }
  })]

  depends_on = [null_resource.gateway_api_crds]
}

resource "kubernetes_manifest" "gateway_class" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata   = { name = "traefik" }
    spec       = { controllerName = "traefik.io/gateway-controller" }
  }
  depends_on = [helm_release.traefik]
}

# ── ArgoCD ────────────────────────────────────────────────────────────────────

# No system taint toleration — Karpenter will provision a workload spot node for ArgoCD pods
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.8.3"
  namespace        = "argocd"
  create_namespace = true

  values = [yamlencode({
    global = {
      nodeSelector = {}
      tolerations  = []
    }
    server        = { replicas = 1 }
    applicationSet = { replicas = 1 }
    configs = {
      params = { "server.insecure" = true }
    }
  })]
}
