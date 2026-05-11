include "root" {
  path = find_in_parent_folders()
}

locals {
  region = read_terragrunt_config(find_in_parent_folders("region.hcl")).locals.region
  env    = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals.env
}

dependency "vpc" {
  config_path = "../vpc"
}

dependency "eks" {
  config_path = "../eks"
}

terraform {
  source = "../../../../modules/addons"
}

generate "k8s_providers" {
  path      = "k8s_providers.tf"
  if_exists = "overwrite"
  contents  = <<EOF
provider "helm" {
  kubernetes {
    host                   = "${dependency.eks.outputs.cluster_endpoint}"
    cluster_ca_certificate = base64decode("${dependency.eks.outputs.cluster_certificate_authority_data}")
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", "${dependency.eks.outputs.cluster_name}"]
    }
  }
}

provider "kubernetes" {
  host                   = "${dependency.eks.outputs.cluster_endpoint}"
  cluster_ca_certificate = base64decode("${dependency.eks.outputs.cluster_certificate_authority_data}")
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", "${dependency.eks.outputs.cluster_name}"]
  }
}
EOF
}

inputs = {
  cluster_name                       = dependency.eks.outputs.cluster_name
  cluster_endpoint                   = dependency.eks.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.eks.outputs.cluster_certificate_authority_data
  oidc_provider_arn                  = dependency.eks.outputs.oidc_provider_arn
  oidc_provider_url                  = dependency.eks.outputs.cluster_oidc_issuer_url
  node_iam_role_name                 = dependency.eks.outputs.node_iam_role_name
  node_iam_role_arn                  = dependency.eks.outputs.node_iam_role_arn
  node_security_group_id             = dependency.eks.outputs.node_security_group_id
  private_subnet_ids                 = dependency.vpc.outputs.private_subnet_ids
  vpc_id                             = dependency.vpc.outputs.vpc_id
}
