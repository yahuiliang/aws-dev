# EC2 远程开发机 — 参考文档

## Terraform 资源图

```
data.aws_vpc.default
data.aws_subnets.default → data.aws_subnet.dev (AZ)
data.aws_ami.ubuntu (jammy arm64)
data.aws_caller_identity.current

aws_key_pair.dev
aws_security_group.dev          # ingress 22 from allowed_ssh_cidr
aws_ebs_volume.data             # gp3, encrypted, same AZ as subnet
aws_iam_role.dev_instance       # count: auto_stop_idle_minutes > 0
aws_iam_role_policy.dev_self_stop
aws_iam_instance_profile.dev
aws_spot_instance_request.dev   # user_data_base64, root gp3
aws_volume_attachment.data      # /dev/xvdf
data.aws_instance.dev           # read public_ip after attach
```

### Outputs

| Output | 用途 |
|--------|------|
| `public_ip` | SSH、vscode-ssh.sh |
| `instance_id` | 运维参考 |
| `ssh_command` | 快速连接 |
| `data_volume_id` | EBS 卷追踪 |

### 模板嵌套

```
main.tf
  templatefile("user-data.sh.tpl", { setup_script = ... })
    setup_script = templatefile("files/dev-box-setup.sh.tpl", {
      dev_username, install_docker,
      ssh_public_key, auto_stop_*, aws_region,
      auto_stop_script_b64, block_ssh_until_ready
    })
```

## variables.tf 完整列表

| 变量 | 默认 | 说明 |
|------|------|------|
| `aws_region` | `us-west-2` | 区域 |
| `project_name` | `vibe-dev` | 资源命名前缀 |
| `instance_type` | `t4g.micro` | Spot 规格 |
| `spot_max_price` | `""` | 空=按需价上限 |
| `root_volume_size` | 8 | 系统盘 GB |
| `data_volume_size` | 8 | 数据盘 GB |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub` | 本地公钥 |
| `allowed_ssh_cidr` | (必填) | 公网 IP/32 |
| `install_docker` | false | Docker |
| `dev_username` | dev | SSH 用户 |
| `auto_stop_idle_minutes` | 120 | 0=关闭 |
| `auto_stop_check_interval_minutes` | 5 | 检测间隔 |
| `block_ssh_until_ready` | true | 初始化 SSH 门禁 |

## dev-box-setup.sh.tpl 函数清单

| 函数 | 作用 |
|------|------|
| `find_data_device` / `wait_for_data_device` | 发现 EBS 块设备 |
| `setup_dev_user` | 创建 dev 用户、authorized_keys |
| `setup_login_hint` | .bashrc 初始化提示 |
| `mount_data_volume` | 格式化、fstab、home 软链 |
| `setup_ssh_hardening` | sshd 配置、ubuntu 锁定、ssh-gate |
| `setup_packages` | apt 基础包 |
| `setup_git` | git 全局配置占位 |
| `setup_cpp_toolchain` | g++/cmake/clang/clangd 校验 |
| `ensure_dev_nvm` | swap + nvm Node 20 |
| `setup_autostop` | auto-stop timer + keepalive |

main 顺序：`setup_dev_user` → `setup_ssh_hardening` → 等盘 → `mount_data_volume` → `setup_packages` → `setup_autostop` → `/data/.initialized`

## 本地脚本索引

| 脚本 | 说明 |
|------|------|
| `check-local.sh` | aws/terraform/jq 检查 |
| `set-my-ip.sh` | 公网 IP → `allowed_ssh_cidr` |
| `up.sh` | init + apply + wait-ready |
| `down.sh` | targeted destroy 实例+attachment |
| `destroy-all.sh` | 全量 destroy |
| `restart.sh` | taint spot + apply + wait |
| `stop.sh` / `start.sh` | EC2 stop/start（非 terraform） |
| `ssh.sh` | 终端 SSH |
| `info.sh` | terraform output |
| `vscode-ssh.sh` | 写 ~/.ssh/config |
| `wait-ready.sh` | SSH + initialized 轮询 |
| `fix-instance.sh` | 远程重跑 setup |

### scripts/lib/

| 文件 | 导出 |
|------|------|
| `tfvars.sh` | `tfvar()`, `update_allowed_ssh_cidr()` |
| `ssh_config.sh` | `write_vscode_ssh_block()` |

## 实例内关键路径

| 路径 | 说明 |
|------|------|
| `/data` | EBS 挂载点 |
| `/data/home/dev` | 持久化 home |
| `/data/.initialized` | setup 完成标记 |
| `~/projects` | 代码目录 |
| `/usr/local/bin/dev-box-setup.sh` | bootstrap 脚本 |
| `/usr/local/bin/dev-box-ssh-gate` | SSH 门禁 |
| `/usr/local/bin/auto-stop.sh` | 空闲停机 |
| `/usr/local/bin/keepalive` | 延长在线 |

## systemd 单元

| 单元 | 作用 |
|------|------|
| `dev-box-setup.service` | 开机 oneshot bootstrap |
| `dev-box-setup-retry.timer` | 每 2min 重试直到 initialized |
| `auto-stop.timer` | 空闲检测（若启用） |

## 测试文件

| 文件 | 覆盖 |
|------|------|
| `tests/terraform.bats` | validate、fmt、模板、cidr validation |
| `tests/tfvars.bats` | tfvar 解析、update_allowed_ssh_cidr |
| `tests/ssh_config.bats` | write_vscode_ssh_block |
| `tests/check_template.sh` | dev-box-setup.tpl 渲染冒烟 |
| `tests/fixtures/sample.tfvars` | 测试用 tfvars |
| `tests/fixtures/test_key.pub` | 测试用公钥 |

## 典型扩展场景

### 例：新增 `install_rust` 开关

1. `variables.tf`：`variable "install_rust" { type = bool, default = false }`
2. `terraform.tfvars.example`：`install_rust = false`
3. `main.tf`：templatefile map 加 `install_rust = var.install_rust`
4. `dev-box-setup.sh.tpl`：`INSTALL_RUST="${install_rust}"`，加 `setup_rust()` 在 main 调用
5. `tests/check_template.sh` 若硬编码变量列表需同步
6. `README.md` 文档（用户要求时）

### 例：新增 `make logs` 查看远程 setup 日志

1. `scripts/logs.sh`：读 tfvars + terraform output IP，`ssh ... journalctl -t dev-box-setup -f`
2. `Makefile` 加 `logs` target

### 例：支持第二种实例规格预设

优先用现有 `instance_type` 变量；若要做预设，在 `terraform.tfvars.example` 注释说明即可，避免过度抽象。

## 成本与安全边界

- 成本敏感：默认 VPC、Spot、小盘、自动停机、无 Docker
- 安全默认：单端口、IP 白名单、密钥登录、单用户 SSH、EBS 加密
- 改 `allowed_ssh_cidr` validation 或开放更多端口属于**重大安全变更**，需明确用户意图
