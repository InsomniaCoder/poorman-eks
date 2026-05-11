# GitHub Actions OIDC Setup

This guide walks through bootstrapping the AWS prerequisites so that GitHub Actions can authenticate to AWS using OIDC (no static credentials stored in secrets).

---

## Prerequisites

- AWS CLI configured with credentials that have IAM + S3 + DynamoDB permissions (`aws sts get-caller-identity` should succeed).
- An AWS account ID handy — referenced as `<YOUR_ACCOUNT_ID>` below.
- The GitHub repository is `InsomniaCoder/poorman-eks` (already set in the trust policy).
- `terraform` >= 1.9 and `git` installed locally (only needed if you use the Terraform bootstrap in step 6).

---

## 1. Create the S3 state bucket

```bash
aws s3api create-bucket \
  --bucket poorman-eks-tfstate \
  --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1

aws s3api put-bucket-versioning \
  --bucket poorman-eks-tfstate \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket poorman-eks-tfstate \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

---

## 2. Create the DynamoDB lock table

```bash
aws dynamodb create-table \
  --table-name poorman-eks-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-1
```

---

## 3. Create the GitHub OIDC provider in AWS

> **Note:** This only needs to be done **once per AWS account**. If another project has already registered `token.actions.githubusercontent.com` as an OIDC provider in your account, skip this step and reuse the existing provider ARN.

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

---

## 4. Create the IAM role for GitHub Actions

Save the following trust policy to a file named `trust-policy.json`, replacing `<YOUR_ACCOUNT_ID>` with your actual AWS account ID:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<YOUR_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:InsomniaCoder/poorman-eks:*"
        }
      }
    }
  ]
}
```

> **Production note:** Replace `AdministratorAccess` below with a scoped policy covering only the AWS resources Terraform manages (VPC, EKS, IAM roles, SQS, etc.). `AdministratorAccess` is used here for simplicity in a showcase/dev environment.

```bash
# Save the trust policy above to trust-policy.json first
aws iam create-role \
  --role-name poorman-eks-github-actions \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
  --role-name poorman-eks-github-actions \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

---

## 5. Add GitHub secrets

Navigate to **Settings → Secrets and variables → Actions** in the `InsomniaCoder/poorman-eks` repository and add:

| Secret name    | Value                                                                      |
|----------------|----------------------------------------------------------------------------|
| `AWS_ROLE_ARN` | `arn:aws:iam::<account-id>:role/poorman-eks-github-actions`               |

---

## 6. Bootstrap Terraform snippet (optional)

If you prefer to automate steps 1–4 with Terraform instead of running the AWS CLI commands manually, save the file below as `bootstrap/main.tf` and run it once. State is stored locally — after bootstrap completes you can delete the `bootstrap/` directory.

```hcl
# bootstrap/main.tf — run once to create state backend + GitHub OIDC role
# Usage: cd bootstrap && terraform init && terraform apply
# After this, delete this directory — state is stored locally only

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
}

variable "github_org"  { default = "InsomniaCoder" }
variable "github_repo" { default = "poorman-eks" }

resource "aws_s3_bucket" "tfstate" {
  bucket = "poorman-eks-tfstate"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "poorman-eks-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  name = "poorman-eks-github-actions"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "role_arn" {
  value       = aws_iam_role.github_actions.arn
  description = "Set this as GitHub secret AWS_ROLE_ARN"
}
```
