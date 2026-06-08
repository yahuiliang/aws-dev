variable "aws_region" {
  description = "AWS 区域，湾区推荐 us-west-2；极致延迟 us-west-1；最便宜 us-east-1"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "资源命名前缀"
  type        = string
  default     = "vibe-dev"
}

variable "instance_type" {
  description = "Spot 实例类型，刷题 t4g.micro (ARM)；卡顿可改 t4g.small"
  type        = string
  default     = "t4g.micro"
}

variable "spot_max_price" {
  description = "Spot 最高出价（美元/小时），留空则按按需价"
  type        = string
  default     = "" # empty = on-demand price cap
}

variable "root_volume_size" {
  description = "系统盘大小 (GB)"
  type        = number
  default     = 8
}

variable "data_volume_size" {
  description = "持久化数据盘大小 (GB)，代码和 home 目录，销毁实例不丢"
  type        = number
  default     = 8
}

variable "ssh_public_key_path" {
  description = "本地 SSH 公钥路径"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "allowed_ssh_cidr" {
  description = "允许 SSH 的来源 IP，必须设为你的公网 IP/32"
  type        = string

  validation {
    condition     = !contains(["0.0.0.0/0", "::/0"], var.allowed_ssh_cidr)
    error_message = "allowed_ssh_cidr 不能为全网开放，请改成你的公网 IP/32，例如 \"1.2.3.4/32\"。查 IP: curl -4 ifconfig.me"
  }
}

variable "install_docker" {
  description = "是否安装 Docker（刷题可关）"
  type        = bool
  default     = false
}

variable "install_leetcode_cli" {
  description = "是否安装 leetcode-cli + 离线题面（无浏览器刷题）"
  type        = bool
  default     = true
}

variable "dev_username" {
  description = "开发用户名"
  type        = string
  default     = "dev"
}

variable "auto_stop_idle_minutes" {
  description = "无活动多少分钟后自动停机，0 表示关闭"
  type        = number
  default     = 30
}

variable "auto_stop_check_interval_minutes" {
  description = "空闲检测间隔（分钟）"
  type        = number
  default     = 5
}

variable "block_ssh_until_ready" {
  description = "初始化完成前拒绝 dev SSH 登录（避免装一半就连上去）"
  type        = bool
  default     = true
}
