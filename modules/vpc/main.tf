module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.name
  cidr = var.cidr
  azs  = var.azs

  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "karpenter.sh/discovery"                    = var.cluster_name
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_vpc_ipv4_cidr_block_association" "pod_cidr" {
  vpc_id     = module.vpc.vpc_id
  cidr_block = var.pod_cidr
}

resource "aws_subnet" "pod" {
  count             = length(var.pod_subnets)
  vpc_id            = module.vpc.vpc_id
  cidr_block        = var.pod_subnets[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name                                        = "${var.name}-pod-${var.azs[count.index]}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "karpenter.sh/discovery"                    = var.cluster_name
  }

  depends_on = [aws_vpc_ipv4_cidr_block_association.pod_cidr]
}
