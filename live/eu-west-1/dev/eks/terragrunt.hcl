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

terraform {
  source = "../../../../modules/eks"
}

inputs = {
  cluster_name            = "poorman-eks-${local.env}"
  vpc_id                  = dependency.vpc.outputs.vpc_id
  subnet_ids              = dependency.vpc.outputs.private_subnet_ids
  public_subnet_ids       = dependency.vpc.outputs.public_subnet_ids
  pod_subnet_ids          = dependency.vpc.outputs.pod_subnet_ids
  private_route_table_ids = dependency.vpc.outputs.private_route_table_ids
  vpc_cidr                = dependency.vpc.outputs.vpc_cidr_block
}
