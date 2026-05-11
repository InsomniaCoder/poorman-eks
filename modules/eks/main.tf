module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  cluster_endpoint_public_access  = var.cluster_endpoint_public_access
  cluster_endpoint_private_access = var.cluster_endpoint_private_access

  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        env = {
          AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = "true"
          ENI_CONFIG_LABEL_DEF               = "topology.kubernetes.io/zone"
          ENABLE_PREFIX_DELEGATION           = "true"
          WARM_PREFIX_TARGET                 = "1"
        }
      })
    }
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    system = {
      name           = "system"
      # Multiple instance types to reduce spot eviction risk.
      # All arm64, 2 vCPU / 4 GB — identical spec required for predictable pod scheduling.
      # EKS MNG picks the cheapest available from this pool.
      instance_types = [
        "t4g.medium", # 2 vCPU, 4 GB — Graviton2 burstable, baseline
        "c6g.large",  # 2 vCPU, 4 GB — Graviton2 compute-optimised
        "c7g.large",  # 2 vCPU, 4 GB — Graviton3 compute-optimised
      ]
      capacity_type  = "SPOT"
      ami_type       = "AL2023_ARM_64_STANDARD"

      min_size     = 1
      max_size     = 2
      desired_size = 1

      subnet_ids = [var.subnet_ids[0]]

      disk_size = 20

      labels = {
        role = "system"
      }

      taints = [
        {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      ]

      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
  }
}

# ENIConfig for VPC CNI custom networking — one per AZ
resource "kubernetes_manifest" "eni_config" {
  manifest = {
    apiVersion = "crd.k8s.amazonaws.com/v1alpha1"
    kind       = "ENIConfig"
    metadata = {
      name = "eu-west-1a"
    }
    spec = {
      securityGroups = [module.eks.node_security_group_id]
      subnet         = var.pod_subnet_ids[0]
    }
  }

  depends_on = [module.eks]
}

# fck-nat: cheapest NAT solution (~$1-2/mo spot) instead of NAT Gateway (~$35/mo)
data "aws_ami" "fck_nat" {
  most_recent = true
  owners      = ["568608671756"] # fck-nat maintainer account

  filter {
    name   = "name"
    values = ["fck-nat-al2023-*-arm64-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_security_group" "fck_nat" {
  name_prefix = "${var.cluster_name}-fck-nat-"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-fck-nat"
  }
}

resource "aws_launch_template" "fck_nat" {
  name_prefix   = "${var.cluster_name}-fck-nat-"
  image_id      = data.aws_ami.fck_nat.id
  instance_type = "t4g.nano"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.fck_nat.id]
    source_dest_check           = false # required for NAT
  }

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.cluster_name}-fck-nat"
    }
  }
}

resource "aws_autoscaling_group" "fck_nat" {
  name_prefix         = "${var.cluster_name}-fck-nat-"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [var.public_subnet_ids[0]]

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.fck_nat.id
        version            = "$Latest"
      }

      override {
        instance_type = "t4g.nano"
      }
      override {
        instance_type = "t4g.micro"
      }
      override {
        instance_type = "t4g.small"
      }
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-fck-nat"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Route outbound traffic from private subnets through fck-nat
# Note: fck-nat updates this route itself on startup via its bootstrap script.
# The ENI is looked up by the Name tag. This resource creates the initial route
# and fck-nat will update it on each boot.
resource "aws_route" "private_to_fck_nat" {
  count                  = length(var.private_route_table_ids)
  route_table_id         = var.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  # fck-nat manages this route; we set a placeholder network_interface_id
  # using a data source to find the running instance after it boots.
  # In practice, fck-nat's user-data script updates the route on startup.
  network_interface_id = aws_launch_template.fck_nat.id # placeholder — fck-nat updates this

  lifecycle {
    ignore_changes = [network_interface_id]
  }
}

# S3 Gateway endpoint — free, routes S3 traffic (including ECR layers) within AWS network
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.eu-west-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids

  tags = {
    Name = "${var.cluster_name}-s3-endpoint"
  }
}
