locals {
  common = read_terragrunt_config(find_in_parent_folders("common.hcl"))
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite"
  }
  config = {
    bucket         = local.common.locals.state_bucket
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.common.locals.aws_region
    encrypt        = true
    dynamodb_table = local.common.locals.state_lock_table
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = <<EOF
provider "aws" {
  region = "${local.common.locals.aws_region}"
}
EOF
}
