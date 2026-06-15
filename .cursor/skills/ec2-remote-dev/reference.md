# EC2 远程开发机 — 参考文档

## Terraform 资源图

```
data.aws_vpc.default
data.aws_subnets.default → data.aws_subnet.dev (AZ)
data.aws_ami.ubuntu (jammy arm64)
data.aws_caller_identity.current

aws_key_pair.dev
aws_security_group.dev          # ingress 22 (+ 3389 if install_desktop && desktop_rdp_public)
aws_ebs_volume.data             # gp3, encrypted, same AZ as subnet
aws_iam_role.dev_instance       # count: auto_stop_idle_minutes > 0
aws_iam_role_policy.dev_self_stop
aws_iam_instance_profile.dev
aws_spot_instance_request.dev   # user_data_base64 = base64gzip(...), root gp3
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
  base64gzip(templatefile("user-data.sh.tpl", { setup_script = ... }))
    setup_script = templatefile("files/dev-box-setup.sh.tpl", {
      dev_username, install_docker, install_desktop,
      desktop_rdp_public, dev_rdp_password_b64,
      ssh_public_key, auto_stop_*, aws_region,
      auto_stop_script_b64, block_ssh_until_ready
    })
```

`dev_rdp_password_b64`：tfvars 非空时 `base64encode(var.dev_rdp_password)`，否则 `""`。

## variables.tf 完整列表

| 变量 | 默认 | 说明 |
|------|------|------|
| `aws_region` | `us-west-2` | 区域 |
| `project_name` | `vibe-dev` | 资源命名前缀 |
| `instance_type` | `t4g.micro` | Spot 首选规格 |
| `instance_type_fallbacks` | `["t4g.micro","t4g.medium"]` | Spot 无容量时依次重试；`[]` 关闭 |
| `spot_max_price` | `""` | 空=按需价上限 |
| `root_volume_size` | 8 | 系统盘 GB |
| `data_volume_size` | 8 | 数据盘 GB |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub` | 本地公钥 |
| `allowed_ssh_cidr` | (必填) | 公网 IP/32 |
| `install_docker` | false | Docker |
| `install_desktop` | true | XFCE + xrdp + Firefox |
| `desktop_rdp_public` | false | true=对 allowed_ssh_cidr 开放 3389 |
| `dev_rdp_password` | `""` | RDP 密码（sensitive） |
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
| `setup_packages` | apt 基础包 + 调用子 setup |
| `setup_git` | git 全局配置占位 |
| `setup_cpp_toolchain` | g++/cmake/clang/clangd 校验 |
| `ensure_dev_nvm` | swap + nvm Node 20 |
| `setup_desktop` | XFCE + xrdp + 密码 + 监听地址 |
| `ensure_desktop_browser` | Firefox（tar 包到 /opt/firefox） |
| `setup_autostop` | auto-stop timer + keepalive |
| `mark_setup_complete` | 写 setup-complete + .initialized |

main 顺序：`setup_dev_user` → `setup_ssh_hardening` → 等盘 → `mount_data_volume` → `setup_packages`（含 desktop）→ `setup_autostop` → `mark_setup_complete`

`setup_packages` 内：`setup_git` → `setup_cpp_toolchain` → `ensure_dev_nvm` → Docker（可选）→ `setup_desktop`

## 本地脚本索引

| 脚本 | 说明 |
|------|------|
| `check-local.sh` | aws/terraform/jq 检查 |
| `set-my-ip.sh` | 公网 IP → `allowed_ssh_cidr` |
| `up.sh` | init + spot_apply + wait-ready |
| `down.sh` | targeted destroy 实例+attachment |
| `destroy-all.sh` | 全量 destroy |
| `restart.sh` | taint spot + spot_apply + wait |
| `stop.sh` / `start.sh` | EC2 stop/start；`start` 含 Spot 等待、refresh IP、`vscode-ssh.sh` |
| `ssh.sh` | 终端 SSH |
| `info.sh` | terraform output |
| `vscode-ssh.sh` | 写 ~/.ssh/config |
| `wait-ready.sh` | SSH + remote_setup_ready_script 轮询 |
| `fix-instance.sh` | render_setup 同步 + 远程重跑 setup |

### scripts/lib/

| 文件 | 导出 |
|------|------|
| `tfvars.sh` | `tfvar()`, `tfvar_list()`, `update_allowed_ssh_cidr()`, `update_dev_rdp_password()`, `ensure_dev_rdp_password()` |
| `spot_apply.sh` | `spot_instance_types()`, `spot_apply_with_fallback()` |
| `ec2_start.sh` | `start_instance_with_spot_retry()` — Spot stop/start 状态等待与重试 |
| `ssh_config.sh` | `write_vscode_ssh_block()` |
| `render_setup.sh` | `render_dev_box_setup()` |
| `ready_check.sh` | `remote_setup_ready_script()` |

### spot_apply_with_fallback 行为

1. 从 tfvars 读 `instance_type` + `instance_type_fallbacks`（去重保序）
2. 对每个 type 执行 `terraform apply -var=instance_type=...`
3. 成功则返回；`capacity-not-available` 则 taint spot request 并试下一个
4. 其他错误立即失败

## 实例内关键路径

| 路径 | 说明 |
|------|------|
| `/data` | EBS 挂载点 |
| `/data/home/dev` | 持久化 home |
| `/data/.initialized` | 持久化完成时间戳 |
| `/var/lib/dev-box/setup-complete` | 实例本地完成标记（门禁/wait-ready） |
| `~/projects` | 代码目录 |
| `/usr/local/bin/dev-box-setup.sh` | bootstrap 脚本 |
| `/usr/local/bin/dev-box-ssh-gate` | SSH 门禁 |
| `/usr/local/bin/auto-stop.sh` | 空闲停机 |
| `/usr/local/bin/keepalive` | 延长在线 |
| `/opt/firefox/firefox` | 桌面浏览器（install_desktop） |

## systemd 单元

| 单元 | 作用 |
|------|------|
| `dev-box-setup.service` | 开机 oneshot bootstrap |
| `dev-box-setup-retry.timer` | 每 2min 重试直到 setup-complete |
| `auto-stop.timer` | 空闲检测（若启用） |
| `xrdp` | 远程桌面（install_desktop） |

## 测试文件

| 文件 | 覆盖 |
|------|------|
| `tests/terraform.bats` | validate、fmt、模板、cidr validation |
| `tests/tfvars.bats` | tfvar 解析、update_allowed_ssh_cidr |
| `tests/ssh_config.bats` | write_vscode_ssh_block |
| `tests/spot_apply.bats` | spot_instance_types、容量错误检测 |
| `tests/ec2_start.bats` | Spot start 状态判断与重试辅助 |
| `tests/ready.bats` | remote_setup_ready_script |
| `tests/check_template.sh` | 渲染冒烟 + user-data gzip <16KB |
| `tests/fixtures/sample.tfvars` | 测试用 tfvars |
| `tests/fixtures/test_key.pub` | 测试用公钥 |

## 典型扩展场景

### 例：新增 `install_rust` 开关

1. `variables.tf`：`variable "install_rust" { type = bool, default = false }`
2. `terraform.tfvars.example`：`install_rust = false`
3. `main.tf`：templatefile map 加 `install_rust = var.install_rust`
4. `dev-box-setup.sh.tpl`：`INSTALL_RUST="${install_rust}"`，加 `setup_rust()` 在 `setup_packages` 调用
5. `render_setup.sh` 同步参数
6. `ready_check.sh` 若需等待 rust 则加检测
7. `tests/check_template.sh` 的 ARGS 同步
8. `README.md` 文档（用户要求时）

### 例：新增 `make logs` 查看远程 setup 日志

1. `scripts/logs.sh`：读 tfvars + terraform output IP，`ssh ... journalctl -t dev-box-setup -f`
2. `Makefile` 加 `logs` target

### 例：修改就绪判定（新组件装完才算 ready）

在 `ready_check.sh` 的 `remote_setup_ready_script` 中按 tfvars 开关追加远程检查命令；保持与 `dev-box-setup.sh.tpl` 实际安装内容一致。

### 例：支持第二种实例规格预设

优先用现有 `instance_type` + `instance_type_fallbacks`；避免过度抽象。

## 成本与安全边界

- 成本敏感：默认 VPC、Spot、小盘、自动停机、无 Docker
- 安全默认：SSH 单端口白名单、密钥登录、单用户 SSH、EBS 加密；RDP 默认仅 localhost + SSH 隧道
- 改 `allowed_ssh_cidr` validation 或开放更多端口属于**重大安全变更**，需明确用户意图
- user-data 16KB 限制：大改动需考虑拆包或运行时下载
