#!/bin/bash
# =============================================================================
# Claude API Gateway - 服务器端部署脚本
# 使用方法: 将此脚本和 claude-api-gateway.tar.gz 上传到服务器后执行
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DEPLOY_DIR="/www/compose/claude-api-gateway"
DOMAIN="shop.fixingqi.store"
APP_PORT="23000"

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

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 root 用户运行: sudo ./server-deploy.sh"
    exit 1
fi

# 检查压缩包
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARBALL="$SCRIPT_DIR/claude-api-gateway.tar.gz"

if [ ! -f "$TARBALL" ]; then
    TARBALL="/root/claude-api-gateway.tar.gz"
fi

if [ ! -f "$TARBALL" ]; then
    log_error "找不到 claude-api-gateway.tar.gz"
    log_info "请确保压缩包与脚本在同一目录，或放在 /root/ 下"
    exit 1
fi

log_info "找到压缩包: $TARBALL"

# 检查 Docker
if ! command -v docker &> /dev/null; then
    log_error "Docker 未安装，请先安装 Docker"
    exit 1
fi

if ! docker compose version &> /dev/null; then
    log_error "Docker Compose 未安装"
    exit 1
fi

log_success "Docker 环境检查通过"

# 解压项目
log_info "解压项目到 $DEPLOY_DIR ..."
mkdir -p "$(dirname $DEPLOY_DIR)"

if [ -d "$DEPLOY_DIR" ]; then
    log_warning "目录已存在，备份中..."
    mv "$DEPLOY_DIR" "${DEPLOY_DIR}.backup.$(date +%Y%m%d%H%M%S)"
fi

tar -xzf "$TARBALL" -C "$(dirname $DEPLOY_DIR)"
log_success "解压完成"

cd "$DEPLOY_DIR"

# 生成环境配置
log_info "生成环境配置..."
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
log_success "凭证已保存到 credentials.txt"

# 配置防火墙
log_info "配置防火墙..."
if command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=${APP_PORT}/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
fi

# 构建并启动
log_info "构建 Docker 镜像（可能需要几分钟）..."
docker compose build

log_info "启动服务..."
docker compose up -d

log_info "等待服务启动..."
sleep 15

# 健康检查
log_info "检查服务状态..."
docker compose ps

echo ""
echo "=============================================================================="
echo -e "${GREEN}部署完成！${NC}"
echo "=============================================================================="
echo ""
echo -e "管理后台: ${BLUE}http://${DOMAIN}:${APP_PORT}${NC}"
echo ""
echo -e "${YELLOW}管理员令牌:${NC} ${ADMIN_TOKEN}"
echo ""
echo "凭证文件: $DEPLOY_DIR/credentials.txt"
echo ""
echo "常用命令:"
echo "  查看日志:  cd $DEPLOY_DIR && docker compose logs -f app"
echo "  重启服务:  cd $DEPLOY_DIR && docker compose restart"
echo "  停止服务:  cd $DEPLOY_DIR && docker compose down"
echo ""
log_warning "请确保阿里云安全组已开放端口 ${APP_PORT}"
echo "=============================================================================="
