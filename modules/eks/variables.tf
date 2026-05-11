variable "cluster_name" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.33"
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private node subnets"
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnets for fck-nat"
}

variable "pod_subnet_ids" {
  type        = list(string)
  description = "Pod subnets from secondary CIDR (100.64.0.0/10)"
}

variable "private_route_table_ids" {
  type        = list(string)
  description = "Private route table IDs for S3 endpoint and fck-nat route"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block — used for fck-nat security group ingress"
}

variable "cluster_endpoint_public_access" {
  type    = bool
  default = true # set false in production
}

variable "cluster_endpoint_private_access" {
  type    = bool
  default = true
}
