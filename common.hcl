locals {
  aws_region        = "eu-west-1"
  state_bucket      = "poorman-eks-tfstate"       # create this S3 bucket before running
  state_lock_table  = "poorman-eks-tfstate-lock"  # create this DynamoDB table before running
}
