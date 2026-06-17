# AWS Price List API 仅在 us-east-1 / ap-south-1 可用
provider "aws" {
  alias  = "pricing"
  region = "us-east-1"
}

locals {
  # https://docs.aws.amazon.com/general/latest/gr/billing-aws.html
  pricing_locations = {
    "us-east-1"      = "US East (N. Virginia)"
    "us-east-2"      = "US East (Ohio)"
    "us-west-1"      = "US West (N. California)"
    "us-west-2"      = "US West (Oregon)"
    "ap-northeast-1" = "Asia Pacific (Tokyo)"
    "ap-southeast-1" = "Asia Pacific (Singapore)"
    "eu-west-1"      = "EU (Ireland)"
  }

  ebs_gp3_usage_types = {
    "us-east-1"      = "USE1-EBS:VolumeUsage.gp3"
    "us-east-2"      = "USE2-EBS:VolumeUsage.gp3"
    "us-west-1"      = "USW1-EBS:VolumeUsage.gp3"
    "us-west-2"      = "USW2-EBS:VolumeUsage.gp3"
    "ap-northeast-1" = "APN1-EBS:VolumeUsage.gp3"
    "ap-southeast-1" = "APS1-EBS:VolumeUsage.gp3"
    "eu-west-1"      = "EUW1-EBS:VolumeUsage.gp3"
  }

  pricing_location   = lookup(local.pricing_locations, var.aws_region, "US West (Oregon)")
  ebs_gp3_usage_type = lookup(local.ebs_gp3_usage_types, var.aws_region, "USW2-EBS:VolumeUsage.gp3")

  ebs_total_gb = var.root_volume_size + var.data_volume_size

  ebs_gp3_json      = jsondecode(data.aws_pricing_product.ebs_gp3.result)
  ebs_gp3_on_demand = local.ebs_gp3_json.terms.OnDemand
  ebs_gp3_term_key  = one(keys(local.ebs_gp3_on_demand))
  ebs_gp3_dim_key = one(keys(
    local.ebs_gp3_on_demand[local.ebs_gp3_term_key].priceDimensions
  ))
  ebs_gp3_per_gb_month = tonumber(
    local.ebs_gp3_on_demand[local.ebs_gp3_term_key].priceDimensions[local.ebs_gp3_dim_key].pricePerUnit.USD
  )

  spot_hourly_usd = tonumber(data.aws_ec2_spot_price.dev.spot_price)
  ebs_monthly_usd = local.ebs_total_gb * local.ebs_gp3_per_gb_month
  # AWS 月费估算惯例：730 小时/月
  compute_monthly_730h_usd    = local.spot_hourly_usd * 730
  estimated_monthly_total_usd = local.ebs_monthly_usd + local.compute_monthly_730h_usd
}

data "aws_ec2_spot_price" "dev" {
  instance_type     = aws_spot_instance_request.dev.instance_type
  availability_zone = data.aws_subnet.dev.availability_zone

  filter {
    name   = "product-description"
    values = ["Linux/UNIX"]
  }
}

data "aws_pricing_product" "ebs_gp3" {
  provider     = aws.pricing
  service_code = "AmazonEC2"

  filters {
    field = "productFamily"
    value = "Storage"
  }

  filters {
    field = "volumeApiName"
    value = "gp3"
  }

  filters {
    field = "location"
    value = local.pricing_location
  }

  filters {
    field = "usagetype"
    value = local.ebs_gp3_usage_type
  }
}
