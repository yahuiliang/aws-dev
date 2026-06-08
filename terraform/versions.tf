terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.23.0"
    }
  }

  # 可选：取消注释并配置 S3 backend 做远程 state
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "dev-box/terraform.tfstate"
  #   region = "ap-northeast-1"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "terraform"
      Environment = "dev"
    }
  }
}
