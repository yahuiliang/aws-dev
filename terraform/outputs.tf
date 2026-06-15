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

output "estimated_monthly_cost_usd" {
  description = "粗略月费估算（Spot + EBS，不含流量）"
  value       = "~$2-5 (t4g.micro spot + 16GB gp3，按实际开机时间)"
}
