---
name: ec2-remote-dev
description: Guides development and extension of the AWS Spot EC2 remote dev box repo (Terraform + bash + user-data bootstrap). Use when modifying this repository, adding features, debugging deploy/setup flows, extending dev-box tooling, or when the user mentions ec2远程, vibe-dev, dev-box-setup, or remote LeetCode/Cursor SSH workflows.
---

# EC2 远程开发机 — 项目架构 Skill

## 项目目标

用 **Spot EC2 + 持久化 EBS** 搭低成本云开发机，默认面向刷题/LeetCode，推荐 **本地 Cursor + Remote SSH**（仅 22 端口）。

## 架构总览

```
本地 Mac                          AWS (默认 VPC)
┌─────────────────┐              ┌──────────────────────────────┐
│ Makefile        │──make up──►  │ aws_spot_instance_request    │
│ scripts/*.sh    │              │  └─ user-data → dev-box-setup│
│ terraform/      │              │ aws_ebs_volume (gp3, /data)  │
└─────────────────┘              │ aws_security_group (22 only) │
        │                        │ IAM role (auto-stop, 可选)   │
        └── SSH / Cursor ───────►└──────────────────────────────┘
```

**数据持久化**：EBS 挂 `/data`，`dev` 的 home 软链到 `/data/home/dev`。`make down` 只销毁实例，数据盘保留；`make destroy` 删全部。

**就绪标记**：`/data/.initialized` 存在表示 bootstrap 完成。`block_ssh_until_ready=true` 时，完成前 `dev` SSH 被 `dev-box-ssh-gate` 拒绝。

## 目录职责

| 路径 | 职责 |
|------|------|
| `Makefile` | 用户入口，薄包装调用 `scripts/` |
| `terraform/` | AWS 资源定义（Spot、EBS、SG、IAM） |
| `terraform/user-data.sh.tpl` | 首启：写入 setup 脚本 + systemd + 重试 timer |
| `terraform/files/dev-box-setup.sh.tpl` | 实例内 bootstrap 主逻辑（可重复执行） |
| `terraform/files/auto-stop.sh` | 空闲自动停机（经 base64 注入） |
| `scripts/` | 本地编排：deploy、SSH、IP 白名单、修复 |
| `scripts/lib/` | 可单测共享函数（`tfvars.sh`、`ssh_config.sh`） |
| `tests/` | bats 单测（terraform validate、模板渲染、lib 函数） |

详细文件索引与资源依赖见 [reference.md](reference.md)。

## 关键数据流

### 部署 (`make up`)

1. `scripts/up.sh`：确保 `terraform.tfvars`、SSH 公钥、`allowed_ssh_cidr`
2. `terraform apply`：创建 Spot 实例，嵌套 `templatefile` 渲染 user-data
3. `scripts/wait-ready.sh`：轮询 SSH + `/data/.initialized`（及 leetcode wrapper）

### 实例初始化

```
user-data.sh.tpl
  → /usr/local/bin/dev-box-setup.sh（来自 dev-box-setup.sh.tpl）
  → systemd: dev-box-setup.service + dev-box-setup-retry.timer
  → 等待 EBS 设备 → mount /data → 装包 → leetcode → auto-stop
  → touch /data/.initialized
```

**EBS 设备发现**：Nitro 实例上 `/dev/xvdf` 常表现为 `/dev/nvme1n1`，`find_data_device()` 已处理。

### 本地 ↔ 远程连接

- `make cursor` → `scripts/vscode-ssh.sh` → `write_vscode_ssh_block()` 写入 `~/.ssh/config`，Host 名固定 **`aws-vibe-dev`**
- `make set-ip` → 更新 `allowed_ssh_cidr`（换 WiFi 后必跑）

## Terraform 要点

- **默认 VPC**，无 NAT，控制成本
- **AMI**：Ubuntu 22.04 arm64（`t4g.*`）
- **Spot**：`persistent` 类型，`lifecycle.ignore_changes = [ami]`
- **数据盘 AZ**：从 subnet 推导，与实例同 AZ（`data.aws_subnet.dev`）
- **变量注入链**：`variables.tf` → `main.tf` templatefile 参数 → `dev-box-setup.sh.tpl` 内 `${...}` 占位

新增 Terraform 变量时，同步更新：`variables.tf`、`terraform.tfvars.example`、`main.tf` 的 templatefile 参数、必要时 `dev-box-setup.sh.tpl`。

## 扩展开发指南

### 添加预装软件 / 工具链

首选修改 `terraform/files/dev-box-setup.sh.tpl`：

- 系统包 → `setup_packages()` 的 `apt-get install`
- 用户级工具 → 新建 `setup_*()` 函数，在 main 末尾、`/data/.initialized` 之前调用
- 需 swap 的大安装（参考 Node/nvm）→ 复用 `ensure_dev_nvm()` 的 swap 模式

保持脚本**幂等**（可重复 `sudo /usr/local/bin/dev-box-setup.sh` 或 `make fix`）。

### 添加配置开关

1. `terraform/variables.tf` 加 variable（带 default + description）
2. `terraform/terraform.tfvars.example` 加示例
3. `main.tf` 传入 `dev-box-setup.sh.tpl` 的 templatefile map
4. 模板内用 `"${var_name}"` 或 bash 变量读取

### 添加本地命令

1. `scripts/new-command.sh`（`set -euo pipefail`，`ROOT=...` 模式与现有脚本一致）
2. `Makefile` 加 target 与 `.PHONY`
3. 需要读 tfvars 时：`source scripts/lib/tfvars.sh` + `TFVARS_FILE=...`

### 修改自动停机逻辑

- 脚本：`terraform/files/auto-stop.sh`
- 触发：systemd timer，间隔 `auto_stop_check_interval_minutes`
- 活动判定：SSH 输入、CPU 负载、Docker 容器、`keepalive` 命令
- 需要 `auto_stop_idle_minutes > 0` 才会创建 IAM role（`ec2:StopInstances` + Project tag 条件）

### 修改安全 / SSH

- 白名单：`allowed_ssh_cidr`（禁止 `0.0.0.0/0`，有 validation）
- 仅 `dev` 用户：`setup_ssh_hardening()`，`ubuntu` 账户锁定
- 初始化门禁：`block_ssh_until_ready` + `dev-box-ssh-gate`

## 常用 Make 命令映射

| 命令 | 脚本 | 场景 |
|------|------|------|
| `up` | `up.sh` + `wait-ready.sh` | 首次部署 / 更新 |
| `down` | `down.sh` | 省计算费，保留数据 |
| `destroy` | `destroy-all.sh` | 彻底删除 |
| `restart` | `restart.sh` | Spot 回收 / 实例异常 |
| `fix` | `fix-instance.sh` | setup 失败重跑 |
| `set-ip` | `set-my-ip.sh` | 更新 SSH 白名单 |
| `cursor` | `vscode-ssh.sh` | 写 SSH config |
| `test` | `tests/run.sh` | bats 单测 |

## 测试

```bash
make test   # 需要 brew install bats-core
```

测试覆盖：terraform validate/fmt、模板渲染（`check_template.sh`）、`tfvars.sh` / `ssh_config.sh` 函数。改 lib 或模板后**必须**跑 `make test`。

## 开发约定

- Bash：`set -euo pipefail`；路径用 `ROOT="$(cd "$(dirname "$0")/.." && pwd)"`
- 不引入 NAT / 多 AZ 复杂网络，除非用户明确要求
- 默认 ARM `t4g.micro`；改 x86 需同步改 AMI filter
- 用户文档在 `README.md`；Makefile 注释面向中文用户
- **不要**提交 `terraform.tfvars`、`terraform.tfstate`、`.terraform/`
- 最小化 diff：只改与任务相关的文件，匹配现有命名与风格

## 故障排查速查

| 现象 | 优先检查 |
|------|----------|
| SSH 连不上 | `make set-ip && make up`；密钥路径与 tfvars 一致 |
| Permission denied | setup 未完成 → `make wait-ready`；失败 → `make fix` |
| 数据/home 丢失 | 是否误跑 `make destroy`；EBS 是否仍 attach |
| Spot 容量不足 | tfvars 改 `t4g.small` 或 `make restart` |
| leetcode 不可用 | `/data/.initialized`；`/usr/local/bin/leetcode` wrapper |
| 误自动停机 | SSH 里 `keepalive`；调大 `auto_stop_idle_minutes` |

## 延伸阅读

- 完整资源清单、脚本依赖图、模板变量表：[reference.md](reference.md)
