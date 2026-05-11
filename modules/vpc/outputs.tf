output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "pod_subnet_ids" {
  value = aws_subnet.pod[*].id
}

output "vpc_cidr_block" {
  value = module.vpc.vpc_cidr_block
}

output "pod_cidr_block" {
  value = var.pod_cidr
}

output "azs" {
  value = module.vpc.azs
}

output "private_route_table_ids" {
  value = module.vpc.private_route_table_ids
}
