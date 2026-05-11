include "root" {
  path = find_in_parent_folders()
}

locals {
  region = read_terragrunt_config(find_in_parent_folders("region.hcl")).locals.region
  env    = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals.env
}

terraform {
  source = "../../../../modules/vpc"
}

inputs = {
  name            = "poorman-eks-${local.env}"
  cidr            = "10.0.0.0/16"
  azs             = ["eu-west-1a"]
  private_subnets = ["10.0.1.0/24"]
  public_subnets  = ["10.0.0.0/24"]
  pod_cidr        = "100.64.0.0/10"
  pod_subnets     = ["100.64.0.0/18"]
  cluster_name    = "poorman-eks-${local.env}"
}
