#!/bin/bash
# =============================================================================
# Claude API Gateway - 阿里云自动化部署脚本
# 适用于: Alibaba Cloud Linux (alinux)
# 域名: http://shop.fixingqi.store
# =============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置变量
DEPLOY_DIR="/www/compose/claude-api-gateway"
DOMAIN="shop.fixingqi.store"
APP_PORT="23000"
POSTGRES_PORT="35432"
REDIS_PORT="36379"

# 打印带颜色的消息
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 生成随机密码
generate_password() {
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
}

# 生成随机令牌
generate_token() {
    openssl rand -hex 32
}

# 检查是否为 root 用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 用户运行此脚本"
        log_info "使用: sudo bash $0"
        exit 1
    fi
}

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        log_error "无法检测操作系统类型"
        exit 1
    fi
    log_info "检测到系统: $OS $VERSION"
}

# 安装 Docker (阿里云 Linux)
install_docker() {
    log_info "检查 Docker 安装状态..."

    if command -v docker &> /dev/null; then
        log_success "Docker 已安装: $(docker --version)"
    else
        log_info "开始安装 Docker..."

        # 阿里云 Linux 使用 dnf/yum
        if command -v dnf &> /dev/null; then
            dnf install -y dnf-utils
            dnf config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
            dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        elif command -v yum &> /dev/null; then
            yum install -y yum-utils
            yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        else
            log_error "不支持的包管理器"
            exit 1
        fi

        log_success "Docker 安装完成"
    fi

    # 启动并设置开机自启
    systemctl start docker
    systemctl enable docker
    log_success "Docker 服务已启动并设置开机自启"

    # 配置 Docker 镜像加速（阿里云）
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
    log_success "Docker 镜像加速已配置"
}

# 安装 Docker Compose
install_docker_compose() {
    log_info "检查 Docker Compose..."

    if docker compose version &> /dev/null; then
        log_success "Docker Compose 已安装: $(docker compose version)"
    else
        log_info "安装 Docker Compose 插件..."
        if command -v dnf &> /dev/null; then
            dnf install -y docker-compose-plugin
        else
            yum install -y docker-compose-plugin
        fi
        log_success "Docker Compose 安装完成"
    fi
}

# 安装 Git
install_git() {
    log_info "检查 Git..."

    if command -v git &> /dev/null; then
        log_success "Git 已安装: $(git --version)"
    else
        log_info "安装 Git..."
        if command -v dnf &> /dev/null; then
            dnf install -y git
        else
            yum install -y git
        fi
        log_success "Git 安装完成"
    fi
}

# 创建部署目录和配置文件
setup_project() {
    log_info "设置项目目录: $DEPLOY_DIR"

    mkdir -p "$DEPLOY_DIR"
    cd "$DEPLOY_DIR"

    # 生成安全凭证
    ADMIN_TOKEN=$(generate_token)
    POSTGRES_PASSWORD=$(generate_password)

    log_info "生成配置文件..."

    # 创建 .env 文件
    cat > .env << EOF
# =============================================================================
# Claude API Gateway 环境配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

# 管理员令牌 (登录后台必须)
ADMIN_TOKEN=${ADMIN_TOKEN}

# 数据库配置
DSN=postgres://postgres:${POSTGRES_PASSWORD}@postgres:5432/claude_api_gateway
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

# Redis 配置
REDIS_URL=redis://redis:6379

# 应用配置
APP_PORT=${APP_PORT}
APP_URL=http://${DOMAIN}
NODE_ENV=production

# 功能开关
AUTO_MIGRATE=true
ENABLE_RATE_LIMIT=true
ENABLE_SECURE_COOKIES=false
SESSION_TTL=300
API_TEST_TIMEOUT_MS=15000
EOF

    # 创建 docker-compose.yaml
    cat > docker-compose.yaml << 'EOF'
services:
  postgres:
    image: postgres:18
    container_name: claude-api-gateway-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: claude_api_gateway
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - app-network

  redis:
    image: redis:7-alpine
    container_name: claude-api-gateway-redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - app-network

  app:
    image: ghcr.io/ding113/claude-code-hub:main
    container_name: claude-api-gateway-app
    restart: unless-stopped
    ports:
      - "${APP_PORT:-23000}:23000"
    environment:
      - DSN=${DSN}
      - REDIS_URL=${REDIS_URL}
      - ADMIN_TOKEN=${ADMIN_TOKEN}
      - AUTO_MIGRATE=${AUTO_MIGRATE:-true}
      - NODE_ENV=${NODE_ENV:-production}
      - APP_URL=${APP_URL}
      - ENABLE_RATE_LIMIT=${ENABLE_RATE_LIMIT:-true}
      - ENABLE_SECURE_COOKIES=${ENABLE_SECURE_COOKIES:-false}
      - SESSION_TTL=${SESSION_TTL:-300}
      - API_TEST_TIMEOUT_MS=${API_TEST_TIMEOUT_MS:-15000}
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:23000/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    networks:
      - app-network

volumes:
  postgres_data:
  redis_data:

networks:
  app-network:
    driver: bridge
EOF

    log_success "配置文件已生成"

    # 保存凭证到安全文件
    cat > credentials.txt << EOF
================================================================================
Claude API Gateway 部署凭证
生成时间: $(date '+%Y-%m-%d %H:%M:%S')
================================================================================

【重要】请妥善保存以下凭证，这是登录后台的唯一凭证！

管理后台地址: http://${DOMAIN}:${APP_PORT}
管理员令牌 (Admin Token): ${ADMIN_TOKEN}

数据库密码: ${POSTGRES_PASSWORD}

================================================================================
EOF
    chmod 600 credentials.txt

    log_success "凭证已保存到: $DEPLOY_DIR/credentials.txt"
}

# 配置防火墙
setup_firewall() {
    log_info "配置防火墙规则..."

    if command -v firewall-cmd &> /dev/null; then
        # 使用 firewalld
        firewall-cmd --permanent --add-port=${APP_PORT}/tcp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        log_success "防火墙已开放端口 ${APP_PORT}"
    elif command -v iptables &> /dev/null; then
        # 使用 iptables
        iptables -I INPUT -p tcp --dport ${APP_PORT} -j ACCEPT 2>/dev/null || true
        log_success "iptables 已开放端口 ${APP_PORT}"
    else
        log_warning "未检测到防火墙工具，请手动开放端口 ${APP_PORT}"
    fi

    log_warning "请确保阿里云安全组已开放端口 ${APP_PORT}"
}

# 启动服务
start_services() {
    log_info "拉取 Docker 镜像..."
    cd "$DEPLOY_DIR"
    docker compose pull

    log_info "启动服务..."
    docker compose up -d

    log_info "等待服务启动..."
    sleep 10

    # 检查服务状态
    log_info "检查服务状态..."
    docker compose ps
}

# 等待健康检查
wait_for_health() {
    log_info "等待应用启动并通过健康检查..."

    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if curl -sf "http://localhost:${APP_PORT}/api/health" > /dev/null 2>&1; then
            log_success "应用已成功启动！"
            return 0
        fi

        echo -n "."
        sleep 2
        attempt=$((attempt + 1))
    done

    echo ""
    log_warning "健康检查超时，但服务可能仍在启动中"
    log_info "请稍后访问 http://${DOMAIN}:${APP_PORT} 检查"
}

# 显示部署结果
show_result() {
    echo ""
    echo "=============================================================================="
    echo -e "${GREEN}部署完成！${NC}"
    echo "=============================================================================="
    echo ""
    echo -e "管理后台地址: ${BLUE}http://${DOMAIN}:${APP_PORT}${NC}"
    echo ""
    echo -e "${YELLOW}【重要】管理员令牌请查看:${NC}"
    echo -e "  cat $DEPLOY_DIR/credentials.txt"
    echo ""
    echo "常用命令:"
    echo "  查看日志:     cd $DEPLOY_DIR && docker compose logs -f app"
    echo "  重启服务:     cd $DEPLOY_DIR && docker compose restart"
    echo "  停止服务:     cd $DEPLOY_DIR && docker compose down"
    echo "  更新服务:     cd $DEPLOY_DIR && docker compose pull && docker compose up -d"
    echo ""
    echo "API 文档:"
    echo "  Scalar UI:   http://${DOMAIN}:${APP_PORT}/api/actions/scalar"
    echo "  Swagger UI:  http://${DOMAIN}:${APP_PORT}/api/actions/docs"
    echo ""
    echo "=============================================================================="
}

# 主函数
main() {
    echo ""
    echo "=============================================================================="
    echo "  Claude API Gateway - 阿里云自动化部署"
    echo "  目标域名: ${DOMAIN}"
    echo "=============================================================================="
    echo ""

    check_root
    detect_os
    install_docker
    install_docker_compose
    install_git
    setup_project
    setup_firewall
    start_services
    wait_for_health
    show_result
}

# 运行主函数
main "$@"
