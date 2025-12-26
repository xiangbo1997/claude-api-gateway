#!/bin/bash
# =============================================================================
# Claude API Gateway - 阿里云本地构建部署脚本
# 适用于: Alibaba Cloud Linux (alinux)
# 说明: 从源码构建镜像，适合需要自定义修改的场景
# =============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置变量
DEPLOY_DIR="/www/compose/claude-api-gateway"
DOMAIN="shop.fixingqi.store"
APP_PORT="23000"
REPO_URL="https://github.com/ding113/claude-code-hub.git"
BRANCH="main"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

generate_password() {
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
}

generate_token() {
    openssl rand -hex 32
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

install_docker() {
    log_info "检查 Docker..."

    if command -v docker &> /dev/null; then
        log_success "Docker 已安装: $(docker --version)"
    else
        log_info "安装 Docker..."
        if command -v dnf &> /dev/null; then
            dnf install -y dnf-utils
            dnf config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
            dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        elif command -v yum &> /dev/null; then
            yum install -y yum-utils
            yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        fi
        log_success "Docker 安装完成"
    fi

    systemctl start docker
    systemctl enable docker

    # 配置镜像加速
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'EOF'
{
    "registry-mirrors": [
        "https://mirror.ccs.tencentyun.com",
        "https://docker.mirrors.ustc.edu.cn"
    ],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "3"
    }
}
EOF
    systemctl daemon-reload
    systemctl restart docker
}

install_git() {
    if ! command -v git &> /dev/null; then
        log_info "安装 Git..."
        dnf install -y git 2>/dev/null || yum install -y git
    fi
}

clone_repository() {
    log_info "克隆项目仓库..."

    mkdir -p "$(dirname $DEPLOY_DIR)"

    if [ -d "$DEPLOY_DIR" ]; then
        log_warning "目录已存在，备份并重新克隆..."
        mv "$DEPLOY_DIR" "${DEPLOY_DIR}.backup.$(date +%Y%m%d%H%M%S)"
    fi

    git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$DEPLOY_DIR"
    log_success "仓库克隆完成"
}

setup_environment() {
    log_info "配置环境变量..."
    cd "$DEPLOY_DIR"

    ADMIN_TOKEN=$(generate_token)
    POSTGRES_PASSWORD=$(generate_password)

    cat > .env << EOF
# Claude API Gateway 环境配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

ADMIN_TOKEN=${ADMIN_TOKEN}
DSN=postgres://postgres:${POSTGRES_PASSWORD}@postgres:5432/claude_api_gateway
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
DB_USER=postgres
DB_PASSWORD=${POSTGRES_PASSWORD}
DB_NAME=claude_api_gateway
REDIS_URL=redis://redis:6379
APP_PORT=${APP_PORT}
APP_URL=http://${DOMAIN}
NODE_ENV=production
AUTO_MIGRATE=true
ENABLE_RATE_LIMIT=true
ENABLE_SECURE_COOKIES=false
SESSION_TTL=300
API_TEST_TIMEOUT_MS=15000
EOF

    # 修改 docker-compose.yaml 使用本地构建（国内镜像源）
    cat > docker-compose.override.yaml << 'EOF'
# 本地构建覆盖配置（使用国内镜像源）
services:
  app:
    build:
      context: .
      dockerfile: deploy/Dockerfile.china
    image: claude-api-gateway:local
EOF

    # 保存凭证
    cat > credentials.txt << EOF
================================================================================
Claude API Gateway 部署凭证
生成时间: $(date '+%Y-%m-%d %H:%M:%S')
================================================================================

管理后台地址: http://${DOMAIN}:${APP_PORT}
管理员令牌 (Admin Token): ${ADMIN_TOKEN}
数据库密码: ${POSTGRES_PASSWORD}

================================================================================
EOF
    chmod 600 credentials.txt
    log_success "环境配置完成"
}

build_and_start() {
    log_info "构建 Docker 镜像..."
    cd "$DEPLOY_DIR"

    # 构建镜像
    docker compose build --no-cache

    log_info "启动服务..."
    docker compose up -d

    log_info "等待服务启动..."
    sleep 15

    docker compose ps
}

setup_firewall() {
    log_info "配置防火墙..."
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=${APP_PORT}/tcp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi
    log_warning "请确保阿里云安全组已开放端口 ${APP_PORT}"
}

wait_for_health() {
    log_info "等待健康检查..."
    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if curl -sf "http://localhost:${APP_PORT}/api/health" > /dev/null 2>&1; then
            log_success "应用启动成功！"
            return 0
        fi
        echo -n "."
        sleep 2
        attempt=$((attempt + 1))
    done
    echo ""
    log_warning "健康检查超时，请稍后检查"
}

show_result() {
    echo ""
    echo "=============================================================================="
    echo -e "${GREEN}部署完成！${NC}"
    echo "=============================================================================="
    echo ""
    echo -e "管理后台: ${BLUE}http://${DOMAIN}:${APP_PORT}${NC}"
    echo ""
    echo "凭证信息: cat $DEPLOY_DIR/credentials.txt"
    echo ""
    echo "常用命令:"
    echo "  查看日志:  cd $DEPLOY_DIR && docker compose logs -f app"
    echo "  重启服务:  cd $DEPLOY_DIR && docker compose restart"
    echo "  停止服务:  cd $DEPLOY_DIR && docker compose down"
    echo "  重新构建:  cd $DEPLOY_DIR && docker compose build && docker compose up -d"
    echo ""
}

main() {
    echo ""
    echo "=============================================================================="
    echo "  Claude API Gateway - 本地构建部署"
    echo "  域名: ${DOMAIN}"
    echo "=============================================================================="
    echo ""

    check_root
    install_docker
    install_git
    clone_repository
    setup_environment
    setup_firewall
    build_and_start
    wait_for_health
    show_result
}

main "$@"
