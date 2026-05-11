variable "name" {
  type = string
}

variable "cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["eu-west-1a"]
}

variable "private_subnets" {
  type    = list(string)
  default = ["10.0.1.0/24"]
}

variable "public_subnets" {
  type    = list(string)
  default = ["10.0.0.0/24"]
}

variable "pod_cidr" {
  type    = string
  default = "100.64.0.0/10"
}

variable "pod_subnets" {
  type    = list(string)
  default = ["100.64.0.0/18"]
}

variable "cluster_name" {
  type = string
}
