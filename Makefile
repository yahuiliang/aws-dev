# vibe-dev 远程开发机 — 常用命令
# 用法: make <命令>

.PHONY: check init set-ip ip up down destroy restart stop start ssh info cursor vscode fix test wait-ready

# 检查本地环境：aws/terraform/jq 是否安装，AWS 是否已登录
check:
	@./scripts/check-local.sh

# 首次使用：从 example 复制 terraform.tfvars 模板
init:
	@cp -n terraform/terraform.tfvars.example terraform/terraform.tfvars || true
	@echo "运行 make set-ip 自动填入公网 IP，或 make up 部署时会自动填入"

# 自动查公网 IP 并写入 terraform.tfvars（换 WiFi 后连不上时也要跑）
set-ip ip:
	@./scripts/set-my-ip.sh

# 部署 / 更新：创建 Spot 实例、挂数据盘、装开发环境
up:
	@./scripts/up.sh

# 销毁实例但保留数据盘（只付 EBS ~$3/月，代码不丢）
down:
	@./scripts/down.sh

# 销毁全部 AWS 资源含数据盘（彻底停用，不可恢复）
destroy:
	@./scripts/destroy-all.sh

# Spot 被回收或实例异常时，强制重建并重新挂载数据盘
restart:
	@./scripts/restart.sh

# 停止实例省钱（不删资源，只付磁盘；比 down 更快恢复）
stop:
	@./scripts/stop.sh

# 启动已停止的实例（IP 可能变，之后跑 make cursor）
start:
	@./scripts/start.sh

# 终端 SSH 登录远程 dev 用户
ssh:
	@./scripts/ssh.sh

# 查看 IP、实例 ID 等 Terraform 输出
info:
	@./scripts/info.sh

# 写入 ~/.ssh/config，供 Cursor / VS Code Remote SSH 连接 aws-vibe-dev
cursor vscode:
	@./scripts/vscode-ssh.sh

# user-data 失败时修复 dev 用户 SSH、数据盘与开发环境
fix:
	@./scripts/fix-instance.sh

# 单元测试（brew install bats-core）
test:
	@./tests/run.sh

# 等待实例 setup 完成（make up 已自动调用）
wait-ready:
	@chmod +x ./scripts/wait-ready.sh && ./scripts/wait-ready.sh
