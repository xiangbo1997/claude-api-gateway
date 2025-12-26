#!/bin/bash
# Claude API Gateway 预构建部署脚本
# 使用本地已构建好的 .next 目录，服务器无需执行 bun run build

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Claude API Gateway 预构建部署脚本${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# 检查是否在项目根目录
if [ ! -f "docker-compose.prebuilt.yaml" ] || [ ! -d ".next" ]; then
    echo -e "${RED}错误: 请在项目根目录运行此脚本${NC}"
    echo -e "${RED}且确保 .next 目录存在（需要先在本地构建）${NC}"
    echo "当前目录: $(pwd)"
    exit 1
fi

# 检查 Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}错误: Docker 未安装${NC}"
    echo "请先安装 Docker: curl -fsSL https://get.docker.com | sh"
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo -e "${RED}错误: Docker Compose 未安装${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Docker 和 Docker Compose 已安装${NC}"

# 生成随机字符串
generate_random_string() {
    local length=${1:-32}
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "$length" | head -n 1
}

# 检查并创建 .env
if [ ! -f ".env" ]; then
    echo -e "${YELLOW}未找到 .env 文件，正在创建...${NC}"

    ADMIN_TOKEN=$(generate_random_string 32)
    DB_PASSWORD=$(generate_random_string 24)

    cat > .env << EOF
# 管理员令牌（登录后台使用）
ADMIN_TOKEN=${ADMIN_TOKEN}

# 自动迁移控制
AUTO_MIGRATE=true

# 数据库配置
DB_USER=postgres
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=claude_code_hub

# 应用配置
APP_PORT=23000

# Cookie 安全策略（HTTP 访问需设为 false）
ENABLE_SECURE_COOKIES=false

# Redis 配置
ENABLE_RATE_LIMIT=true

# Session 配置
SESSION_TTL=300
EOF

    echo -e "${GREEN}✓ .env 文件已创建${NC}"
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  重要信息 - 请妥善保存！${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo -e "管理员令牌 (ADMIN_TOKEN): ${GREEN}${ADMIN_TOKEN}${NC}"
    echo -e "数据库密码 (DB_PASSWORD): ${GREEN}${DB_PASSWORD}${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
else
    echo -e "${GREEN}✓ .env 文件已存在${NC}"
fi

# 创建数据目录
echo -e "${BLUE}创建数据目录...${NC}"
mkdir -p data/postgres data/redis
echo -e "${GREEN}✓ 数据目录已创建${NC}"

# 停止旧容器
echo -e "${BLUE}停止旧容器（如果存在）...${NC}"
docker compose -f docker-compose.prebuilt.yaml down 2>/dev/null || true
docker compose -f docker-compose.china.yaml down 2>/dev/null || true
docker compose down 2>/dev/null || true

# 构建并启动
echo ""
echo -e "${BLUE}开始构建 Docker 镜像（使用预构建的 .next）...${NC}"
echo -e "${GREEN}无需执行 bun run build，几秒钟即可完成！${NC}"
echo ""

docker compose -f docker-compose.prebuilt.yaml up -d --build

# 等待启动
echo ""
echo -e "${BLUE}等待服务启动...${NC}"
sleep 10

# 检查状态
echo ""
echo -e "${BLUE}检查服务状态...${NC}"
docker compose -f docker-compose.prebuilt.yaml ps

# 获取信息
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
APP_PORT=$(grep -E "^APP_PORT=" .env 2>/dev/null | cut -d'=' -f2 || echo "23000")

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  部署完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "管理后台: ${BLUE}http://${SERVER_IP}:${APP_PORT}${NC}"
echo -e "API 文档: ${BLUE}http://${SERVER_IP}:${APP_PORT}/api/actions/scalar${NC}"
echo ""
echo -e "${YELLOW}常用命令:${NC}"
echo "  查看日志: docker compose -f docker-compose.prebuilt.yaml logs -f app"
echo "  停止服务: docker compose -f docker-compose.prebuilt.yaml down"
echo "  重启服务: docker compose -f docker-compose.prebuilt.yaml restart"
echo ""
echo -e "${YELLOW}如果无法访问，请检查:${NC}"
echo "  1. 阿里云安全组是否开放 ${APP_PORT} 端口"
echo "  2. 服务器防火墙是否允许该端口"
echo ""
