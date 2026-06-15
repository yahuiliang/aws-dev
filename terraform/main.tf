data "aws_caller_identity" "current" {}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# 使用默认 VPC，避免 NAT Gateway 等额外费用
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  subnet_id      = tolist(data.aws_subnets.default.ids)[0]
  ssh_public_key = file(pathexpand(var.ssh_public_key_path))
}

# 数据盘必须与实例在同一 AZ；从 subnet 推导，不能单独取 region 第一个 AZ
data "aws_subnet" "dev" {
  id = local.subnet_id
}

resource "aws_key_pair" "dev" {
  key_name   = "${var.project_name}-key"
  public_key = local.ssh_public_key
}

resource "aws_security_group" "dev" {
  name        = "${var.project_name}-sg"
  description = "Dev box: SSH and optional RDP"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  dynamic "ingress" {
    for_each = var.install_desktop && var.desktop_rdp_public ? [1] : []
    content {
      description = "RDP"
      from_port   = 3389
      to_port     = 3389
      protocol    = "tcp"
      cidr_blocks = [var.allowed_ssh_cidr]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 持久化数据盘 — make down 销毁实例时保留
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.dev.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${var.project_name}-data"
    Role = "persistent-home"
  }
}

resource "aws_iam_role" "dev_instance" {
  count = var.auto_stop_idle_minutes > 0 ? 1 : 0
  name  = "${var.project_name}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "dev_self_stop" {
  count = var.auto_stop_idle_minutes > 0 ? 1 : 0
  name  = "${var.project_name}-self-stop"
  role  = aws_iam_role.dev_instance[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ec2:StopInstances"
      Resource = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
      Condition = {
        StringEquals = {
          "ec2:ResourceTag/Project" = var.project_name
        }
      }
    }]
  })
}

resource "aws_iam_instance_profile" "dev" {
  count = var.auto_stop_idle_minutes > 0 ? 1 : 0
  name  = "${var.project_name}-instance-profile"
  role  = aws_iam_role.dev_instance[0].name
}

resource "aws_spot_instance_request" "dev" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.dev.key_name
  vpc_security_group_ids      = [aws_security_group.dev.id]
  subnet_id                   = local.subnet_id
  associate_public_ip_address = true
  iam_instance_profile        = var.auto_stop_idle_minutes > 0 ? aws_iam_instance_profile.dev[0].name : null
  wait_for_fulfillment        = true

  spot_type  = "persistent"
  spot_price = var.spot_max_price != "" ? var.spot_max_price : null

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  # EC2 user-data 上限 16KB（gzip 压缩后）；setup 脚本较大，必须 gzip
  user_data_base64 = base64gzip(templatefile("${path.module}/user-data.sh.tpl", {
    setup_script = templatefile("${path.module}/files/dev-box-setup.sh.tpl", {
      dev_username                     = var.dev_username
      install_docker                   = var.install_docker
      install_desktop                  = var.install_desktop
      desktop_rdp_public               = var.desktop_rdp_public
      dev_rdp_password_b64             = var.dev_rdp_password != "" ? base64encode(var.dev_rdp_password) : ""
      ssh_public_key                   = local.ssh_public_key
      auto_stop_idle_minutes           = var.auto_stop_idle_minutes
      auto_stop_check_interval_minutes = var.auto_stop_check_interval_minutes
      aws_region                       = var.aws_region
      auto_stop_script_b64             = var.auto_stop_idle_minutes > 0 ? base64encode(file("${path.module}/files/auto-stop.sh")) : ""
      block_ssh_until_ready            = var.block_ssh_until_ready
    })
  }))

  tags = {
    Name = "${var.project_name}-spot"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_spot_instance_request.dev.spot_instance_id

  # 实例重建时自动重新挂载
  stop_instance_before_detaching = true
}

data "aws_instance" "dev" {
  instance_id = aws_spot_instance_request.dev.spot_instance_id

  depends_on = [aws_volume_attachment.data]
}
