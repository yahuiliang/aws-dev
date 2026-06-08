# AWS 远程开发机（Spot + 持久化盘）

本地电脑性能不够时，用 **Spot EC2 + 持久化 EBS** 搭一台便宜云开发机，默认面向 **刷题 / LeetCode**（也可做小项目 vibe coding）。

**推荐用法：本地 Cursor + Remote SSH**，只暴露 22 端口。

**默认规格：** `t4g.micro`（Graviton ARM，同区域最便宜档）+ 8GB 系统盘 + 8GB 数据盘。

## 架构

```
┌─────────────┐     SSH（仅 22 端口）        ┌──────────────────┐
│ Cursor/Mac  │ ───────────────────────────► │  Spot EC2        │
│  Remote SSH │                              │  t4g.micro (ARM) │
└─────────────┘                              └────────┬─────────┘
                                                      │ 挂载
                                             ┌────────▼─────────┐
                                             │  EBS gp3 数据盘   │
                                             │  /data (代码/home)│
                                             │  实例销毁不丢数据  │
                                             └──────────────────┘
```

## 成本估算（约）

| 项目 | 参考价格 |
|------|----------|
| t4g.micro Spot (ARM) | ~$0.004–0.008/小时（≈ $2–6/月 若 24h 开） |
| 16GB gp3 磁盘（8+8） | ~$1.3/月 |
| 默认 VPC / 公网 IP | 无 NAT 费用 |

**省钱技巧：**

- 不用时 `make stop` 停实例（只付 EBS）
- 默认 **30 分钟无活动自动停机**
- 默认 `us-west-2`（湾区低延迟）；极致延迟 `us-west-1`；最便宜 `us-east-1`
- 卡顿可改 `instance_type = "t4g.small"`（仍用 ARM）

## 前置条件

1. [AWS 账号](https://aws.amazon.com/)（需 EC2 权限；支持 `aws configure` 或 `aws login`）
2. 本地安装：

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform awscli jq
aws login          # 或 aws configure
```

3. 检查环境：

```bash
make check
```

## 快速开始

```bash
# 1. 生成配置文件
make init

# 2. 自动填入公网 IP（或手动编辑 terraform/terraform.tfvars）
make set-ip

# 3. 部署（make up 会等到环境就绪再提示连接，约 5–10 分钟）
make up

# 4. 配置 Cursor Remote SSH
make cursor

# 5. Cursor 里：Remote-SSH → 连接 aws-vibe-dev
```

`terraform.tfvars` 关键项：

```hcl
instance_type          = "t4g.micro"    # ARM 最便宜档
allowed_ssh_cidr       = "1.2.3.4/32"  # 必改，你的公网 IP
install_docker         = false         # 刷题默认不装
install_leetcode_cli   = true          # leetcode-cli + 离线题面
auto_stop_idle_minutes = 30
block_ssh_until_ready  = true          # 初始化完成前拒绝 SSH
```

## 日常命令

| 命令 | 说明 |
|------|------|
| `make up` | 创建/更新实例（**自动等待** setup 完成） |
| `make wait-ready` | 单独等待环境就绪 |
| `make set-ip` | 换 WiFi 后更新 SSH 白名单 IP |
| `make down` | 销毁实例（**数据盘保留**，约 $1.3/月） |
| `make destroy` | 销毁全部资源含数据盘（不可恢复） |
| `make restart` | Spot 被回收或改配置后一键重建 |
| `make stop` / `make start` | 临时停机省钱 |
| `make ssh` | 终端 SSH 登录 |
| `make cursor` | 写入 `~/.ssh/config`（Cursor Remote SSH） |
| `make info` | 查看 IP 等信息 |
| `make fix` | setup 异常时重跑 dev-box-setup |
| `make setup-leetcode` | 补装 LeetCode 环境（一般不需要） |
| `make test` | 运行单元测试（需 `brew install bats-core`） |
| `keepalive`（SSH 内） | 重置自动停机计时 |

## 开发机已预装

- Git（已配置 `user.name` / `user.email` 占位，请改成你的）、Python3、Node.js (nvm Node 20)、tmux、zsh、ripgrep
- **C++**：g++（build-essential）、clang、cmake、gdb、clang-format、ninja-build
- **leetcode-cli** + doocs/leetcode 离线题面（`install_leetcode_cli = true`）
- Docker 默认**不装**（需要时在 tfvars 设 `install_docker = true`）

代码目录：`~/projects/leetcode`（持久化在 `/data/home/dev/...`）

部署后检查：`leetcode --help` 或 `test -f /data/.initialized && echo OK`。

**避免提前连：** 默认 `block_ssh_until_ready = true`，初始化完成前 SSH 会提示稍后再连；`make up` 也会等到就绪才结束。

## 安全配置（默认）

- **仅 SSH 22 端口**
- **IP 白名单**：`allowed_ssh_cidr` 必须为你的公网 IP/32（禁止 `0.0.0.0/0`）
- **密钥登录**，禁止密码
- **仅 `dev` 用户**可 SSH，`ubuntu` 账户已禁用
- **30 分钟无活动自动停机**

## 空闲自动停机

**30 分钟无活动** 后实例自动 `stop`。满足任一条件视为有活动：

- SSH / Cursor Remote 终端有输入
- CPU 负载较高（编译、测试中）
- Docker 容器在运行（若已安装）
- 执行过 `keepalive`

长时间只读代码时，SSH 里执行 `keepalive` 可延长在线时间。

## Spot 被回收怎么办？

```bash
make restart   # 或 make up
make cursor    # IP 可能变了
```

## 完全删除（含数据盘）

```bash
make destroy
```

## Cursor 推荐

1. 安装 **Remote - SSH** 扩展（Cursor 通常自带）
2. `make cursor` 后连接 `aws-vibe-dev`
3. 远程扩展按需安装：Python、C/C++ 等

## 故障排查

- **Terraform 报错 allowed_ssh_cidr**：改成你的公网 IP/32，或 `make set-ip`
- **SSH 连不上 / Permission denied (publickey)**：换网络后 `make set-ip && make up`；setup 失败则 `make fix` 或 `make restart`
- **Cursor 连不上**：`make cursor` 更新 IP；确认本地密钥与 tfvars 里 `ssh_public_key_path` 一致
- **Spot 容量不足**：改 `t4g.small` 或 `make restart` 换 AZ 重试
