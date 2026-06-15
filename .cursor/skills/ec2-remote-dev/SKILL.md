---
name: ec2-remote-dev
description: Guides development and extension of the AWS Spot EC2 remote dev box repo (Terraform + bash + user-data bootstrap). Use when modifying this repository, adding features, debugging deploy/setup flows, extending dev-box tooling, or when the user mentions ec2远程, vibe-dev, dev-box-setup, or remote LeetCode/Cursor SSH workflows.
---

# EC2 远程开发机 — 项目架构 Skill

## 项目目标

用 **Spot EC2 + 持久化 EBS** 搭低成本云开发机，默认面向刷题/LeetCode，推荐 **本地 Cursor + Remote SSH**（仅 22 端口）。可选 **XFCE + xrdp + Firefox** 远程桌面（Mac Windows App + SSH 隧道）。

## 架构总览

```
本地 Mac                          AWS (默认 VPC)
┌─────────────────┐              ┌──────────────────────────────┐
│ Makefile        │──make up──►  │ aws_spot_instance_request    │
│ scripts/*.sh    │              │  └─ user-data (gzip) → setup │
│ terraform/      │              │ aws_ebs_volume (gp3, /data)  │
└─────────────────┘              │ aws_security_group (22, 可选3389)│
        │                        │ IAM role (auto-stop, 可选)   │
        └── SSH / Cursor ───────►└──────────────────────────────┘
```

**数据持久化**：EBS 挂 `/data`，`dev` 的 home 软链到 `/data/home/dev`。`make down` 只销毁实例，数据盘保留；`make destroy` 删全部。

**就绪标记**（两层，勿混淆）：
- `/var/lib/dev-box/setup-complete` — **实例本地**，SSH 门禁与 `wait-ready` 依据；实例重建后消失，避免数据盘旧状态误判
- `/data/.initialized` — **持久化**，数据盘上的完成时间戳

`block_ssh_until_ready=true` 时，完成前 `dev` SSH 被 `dev-box-ssh-gate` 拒绝。

## 目录职责

| 路径 | 职责 |
|------|------|
| `Makefile` | 用户入口，薄包装调用 `scripts/` |
| `terraform/` | AWS 资源定义（Spot、EBS、SG、IAM） |
| `terraform/user-data.sh.tpl` | 首启：写入 setup 脚本 + systemd + 重试 timer |
| `terraform/files/dev-box-setup.sh.tpl` | 实例内 bootstrap 主逻辑（可重复执行） |
| `terraform/files/auto-stop.sh` | 空闲自动停机（经 base64 注入） |
| `scripts/` | 本地编排：deploy、SSH、IP 白名单、修复 |
| `scripts/lib/` | 可单测共享函数（见下表） |
| `tests/` | bats 单测（terraform validate、模板渲染、lib 函数） |

| `scripts/lib/` 文件 | 导出 |
|---------------------|------|
| `tfvars.sh` | `tfvar()`, `tfvar_list()`, `update_allowed_ssh_cidr()`, `ensure_dev_rdp_password()` |
| `spot_apply.sh` | `spot_apply_with_fallback()` — Spot 容量不足时按 `instance_type_fallbacks` 重试 |
| `ssh_config.sh` | `write_vscode_ssh_block()` |
| `render_setup.sh` | `render_dev_box_setup()` — 与 `main.tf` 同参数渲染 setup 模板 |
| `ready_check.sh` | `remote_setup_ready_script()` — 按 tfvars 开关生成就绪检测脚本 |

详细文件索引与资源依赖见 [reference.md](reference.md)。

## 关键数据流

### 部署 (`make up`)

1. `scripts/up.sh`：确保 `terraform.tfvars`、SSH 公钥、`allowed_ssh_cidr`；`install_desktop=true` 时 `ensure_dev_rdp_password`
2. `spot_apply_with_fallback`：`terraform apply`，Spot 无容量时按 `instance_type_fallbacks` 依次 `-var=instance_type=...` 重试
3. `scripts/wait-ready.sh`：SSH + `remote_setup_ready_script`（含 xrdp/Firefox 等可选检查）

### 实例初始化

```
user-data.sh.tpl (base64gzip，须 <16KB)
  → /usr/local/bin/dev-box-setup.sh（来自 dev-box-setup.sh.tpl）
  → systemd: dev-box-setup.service + dev-box-setup-retry.timer
  → 等待 EBS 设备 → mount /data → 装包/Node/桌面 → auto-stop
  → mark_setup_complete → /var/lib/dev-box/setup-complete + /data/.initialized
```

**EBS 设备发现**：Nitro 实例上 `/dev/xvdf` 常表现为 `/dev/nvme1n1`，`find_data_device()` 已处理。

### 本地 ↔ 远程连接

- `make cursor` → `scripts/vscode-ssh.sh` → Host 名固定 **`aws-vibe-dev`**
- `make set-ip` → 更新 `allowed_ssh_cidr`（换 WiFi 后必跑）
- 远程桌面：`install_desktop=true`，默认 xrdp 监听 `127.0.0.1`，经 SSH 隧道连接；`desktop_rdp_public=true` 时对 `allowed_ssh_cidr` 开放 3389

## Terraform 要点

- **默认 VPC**，无 NAT，控制成本
- **AMI**：Ubuntu 22.04 arm64（`t4g.*`）
- **Spot**：`persistent` 类型，`lifecycle.ignore_changes = [ami]`
- **数据盘 AZ**：从 subnet 推导，与实例同 AZ（`data.aws_subnet.dev`）
- **user-data 上限 16KB（gzip 后）**：setup 脚本较大，必须 `base64gzip`；改模板后跑 `make test` 验证
- **变量注入链**：`variables.tf` → `main.tf` templatefile 参数 → `dev-box-setup.sh.tpl` 内 `${...}` 占位

新增 Terraform 变量时，同步更新：`variables.tf`、`terraform.tfvars.example`、`main.tf` 的 templatefile 参数、`dev-box-setup.sh.tpl`、必要时 `render_setup.sh` / `tests/check_template.sh`。

## 扩展开发指南

### 添加预装软件 / 工具链

首选修改 `terraform/files/dev-box-setup.sh.tpl`：

- 系统包 → `setup_packages()` 的 `apt-get install`
- 用户级工具 → 新建 `setup_*()` 函数，在 `setup_packages()` 或 main 流程中调用
- 需 swap 的大安装（参考 Node/nvm）→ 复用 `ensure_dev_nvm()` 的 swap 模式
- 远程桌面相关 → `setup_desktop()` / `ensure_desktop_browser()`

保持脚本**幂等**（可重复 `sudo /usr/local/bin/dev-box-setup.sh` 或 `make fix`）。

### 添加配置开关

1. `terraform/variables.tf` 加 variable（带 default + description）
2. `terraform/terraform.tfvars.example` 加示例
3. `main.tf` 传入 `dev-box-setup.sh.tpl` 的 templatefile map
4. 模板内用 `"${var_name}"` 或 bash 变量读取
5. 若影响就绪判定 → 更新 `ready_check.sh` 的 `remote_setup_ready_script`
6. 若 `fix-instance.sh` 需同步 → 更新 `render_setup.sh`

### 添加本地命令

1. `scripts/new-command.sh`（`set -euo pipefail`，`ROOT=...` 模式与现有脚本一致）
2. `Makefile` 加 target 与 `.PHONY`
3. 需要读 tfvars 时：`source scripts/lib/tfvars.sh` + `TFVARS_FILE=...`
4. 需要 apply 时：复用 `spot_apply_with_fallback` 而非裸 `terraform apply`

### 修改 Spot 部署 / 重建逻辑

- 容量回退：`scripts/lib/spot_apply.sh` + tfvars `instance_type_fallbacks`
- `up.sh` 与 `restart.sh` 均调用 `spot_apply_with_fallback`
- 非容量错误不重试；容量错误会 `taint aws_spot_instance_request.dev` 后换规格

### 修改自动停机逻辑

- 脚本：`terraform/files/auto-stop.sh`
- 触发：systemd timer，间隔 `auto_stop_check_interval_minutes`
- 活动判定：SSH 输入、CPU 负载、Docker 容器、`keepalive` 命令
- 需要 `auto_stop_idle_minutes > 0` 才会创建 IAM role（`ec2:StopInstances` + Project tag 条件）

### 修改安全 / SSH / RDP

- 白名单：`allowed_ssh_cidr`（禁止 `0.0.0.0/0`，有 validation）
- 仅 `dev` 用户：`setup_ssh_hardening()`，`ubuntu` 账户锁定
- 初始化门禁：`block_ssh_until_ready` + `dev-box-ssh-gate`（检查 `setup-complete`）
- RDP：`install_desktop` + `desktop_rdp_public`；密码 `dev_rdp_password`（sensitive，经 base64 注入）

## 常用 Make 命令映射

| 命令 | 脚本 | 场景 |
|------|------|------|
| `up` | `up.sh` + `wait-ready.sh` | 首次部署 / 更新 |
| `down` | `down.sh` | 省计算费，保留数据 |
| `destroy` | `destroy-all.sh` | 彻底删除 |
| `restart` | `restart.sh` | Spot 回收 / 实例异常 |
| `fix` | `fix-instance.sh` | setup 失败重跑（含 render + 远程执行） |
| `set-ip` | `set-my-ip.sh` | 更新 SSH 白名单 |
| `cursor` | `vscode-ssh.sh` | 写 SSH config |
| `test` | `tests/run.sh` | bats 单测 |

## 测试

```bash
make test   # 需要 brew install bats-core
```

测试覆盖：terraform validate/fmt、模板渲染与 **user-data gzip <16KB**（`check_template.sh`）、`tfvars.sh` / `ssh_config.sh` / `spot_apply.sh` / `ready_check.sh`。改 lib 或模板后**必须**跑 `make test`。

## 开发约定

- Bash：`set -euo pipefail`；路径用 `ROOT="$(cd "$(dirname "$0")/.." && pwd)"`
- 不引入 NAT / 多 AZ 复杂网络，除非用户明确要求
- 默认 ARM `t4g.micro`；远程桌面推荐 `t4g.small`；改 x86 需同步改 AMI filter
- 用户文档在 `README.md`；Makefile 注释面向中文用户
- **不要**提交 `terraform.tfvars`、`terraform.tfstate`、`.terraform/`
- 最小化 diff：只改与任务相关的文件，匹配现有命名与风格

## 故障排查速查

| 现象 | 优先检查 |
|------|----------|
| SSH 连不上 | `make set-ip && make up`；密钥路径与 tfvars 一致 |
| Permission denied | setup 未完成 → `make wait-ready`；失败 → `make fix` |
| 数据/home 丢失 | 是否误跑 `make destroy`；EBS 是否仍 attach |
| Spot 容量不足 | 自动 fallback；或 tfvars 改 `instance_type_fallbacks` / `make restart` |
| 误自动停机 | SSH 里 `keepalive`；调大 `auto_stop_idle_minutes` |
| RDP 黑屏 | 检查 `startwm.sh` / `sesman.ini` DefaultWindowManager；见 `setup_desktop()` |
| user-data 过大 | `make test` 中 gzip 检查失败 → 精简 setup 或拆到 S3/后续拉取 |

## 延伸阅读

- 完整资源清单、脚本依赖图、模板变量表：[reference.md](reference.md)
