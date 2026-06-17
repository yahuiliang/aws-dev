output "instance_id" {
  description = "EC2 实例 ID"
  value       = aws_spot_instance_request.dev.spot_instance_id
}

output "instance_type" {
  description = "实际 Spot 实例规格（可能与 tfvars 首选不同，若触发了 fallback）"
  value       = aws_spot_instance_request.dev.instance_type
}

output "public_ip" {
  description = "公网 IP，用于 SSH / VS Code Remote"
  value       = data.aws_instance.dev.public_ip
}

output "ssh_command" {
  description = "SSH 连接命令"
  value       = "ssh ${var.dev_username}@${data.aws_instance.dev.public_ip}"
}

output "data_volume_id" {
  description = "持久化 EBS 卷 ID"
  value       = aws_ebs_volume.data.id
}

output "spot_price_hourly_usd" {
  description = "当前 AZ 的 Spot 单价（美元/小时，查询自 AWS API）"
  value       = local.spot_hourly_usd
}

output "ebs_monthly_usd" {
  description = "EBS gp3 月费（美元，系统盘+数据盘，停机也计费）"
  value       = local.ebs_monthly_usd
}

output "estimated_monthly_cost_usd" {
  description = "月费估算（Spot×730h + EBS，不含流量；实际按开机时长计费）"
  value = format(
    "$%.2f/mo（Spot %s $%.4f/hr ≈ $%.2f + EBS %dGB gp3 ≈ $%.2f，按 730h 开机估算）",
    local.estimated_monthly_total_usd,
    aws_spot_instance_request.dev.instance_type,
    local.spot_hourly_usd,
    local.compute_monthly_730h_usd,
    local.ebs_total_gb,
    local.ebs_monthly_usd,
  )
}
