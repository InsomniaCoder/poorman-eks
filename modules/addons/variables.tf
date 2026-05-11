variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "cluster_certificate_authority_data" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  type = string
}

variable "node_iam_role_name" {
  type        = string
  description = "IAM role name of the system MNG node — used as Karpenter node role"
}

variable "node_iam_role_arn" {
  type = string
}

variable "node_security_group_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "vpc_id" {
  type = string
}
