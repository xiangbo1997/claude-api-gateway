#!/bin/bash
# Claude API Gateway 完整部署脚本（预构建版 + Nginx + HTTPS）
# 域名: shop.fixingqi.store
# IP: 47.92.154.229

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DOMAIN="shop.fixingqi.store"
APP_PORT="23000"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Claude API Gateway 完整部署脚本${NC}"
echo -e "${BLUE}  域名: ${DOMAIN}${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# 检查是否在项目根目录
if [ ! -d ".next" ] || [ ! -f "deploy/Dockerfile.minimal" ]; then
    echo -e "${RED}错误: 请在项目根目录运行此脚本${NC}"
    echo -e "${RED}且确保 .next 目录和 deploy/Dockerfile.minimal 存在${NC}"
    echo "当前目录: $(pwd)"
    exit 1
fi

# 检查 Docker
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}安装 Docker...${NC}"
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

if ! docker compose version &> /dev/null; then
    echo -e "${RED}错误: Docker Compose 未安装${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Docker 已安装${NC}"

# 生成随机字符串
generate_random_string() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "${1:-32}" | head -n 1
}

# 创建 .env 文件
if [ ! -f ".env" ]; then
    echo -e "${YELLOW}创建 .env 配置文件...${NC}"

    ADMIN_TOKEN=$(generate_random_string 32)
    DB_PASSWORD=$(generate_random_string 24)

    cat > .env << EOF
# 管理员令牌
ADMIN_TOKEN=${ADMIN_TOKEN}

# 数据库配置
DB_USER=postgres
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=claude_code_hub

# 应用配置
APP_PORT=${APP_PORT}
APP_URL=https://${DOMAIN}
AUTO_MIGRATE=true

# Cookie 安全（HTTPS 启用后设为 true）
ENABLE_SECURE_COOKIES=true

# Redis 配置
ENABLE_RATE_LIMIT=true
SESSION_TTL=300
EOF

    echo -e "${GREEN}✓ .env 文件已创建${NC}"
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  重要信息 - 请妥善保存！${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo -e "管理员令牌: ${GREEN}${ADMIN_TOKEN}${NC}"
    echo -e "数据库密码: ${GREEN}${DB_PASSWORD}${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
else
    echo -e "${GREEN}✓ .env 文件已存在${NC}"
fi

# 创建数据目录
mkdir -p data/postgres data/redis
echo -e "${GREEN}✓ 数据目录已创建${NC}"

# 停止旧容器
echo -e "${BLUE}停止旧容器...${NC}"
docker rm -f claude-code-hub-app 2>/dev/null || true
docker compose -f docker-compose.prebuilt.yaml down 2>/dev/null || true
docker compose -f docker-compose.minimal.yaml down 2>/dev/null || true
docker compose down 2>/dev/null || true

# 创建最小化 Dockerfile（如果不存在）
if [ ! -f "deploy/Dockerfile.minimal" ]; then
    cat > deploy/Dockerfile.minimal << 'DOCKERFILE'
FROM docker.1ms.run/library/node:22-slim
ENV NODE_ENV=production PORT=3000 HOST=0.0.0.0
WORKDIR /app
COPY --chown=node:node public ./public
COPY --chown=node:node drizzle ./drizzle
COPY --chown=node:node messages ./messages
COPY --chown=node:node .next/standalone ./
COPY --chown=node:node .next/server ./.next/server
COPY --chown=node:node .next/static ./.next/static
USER node
EXPOSE 3000
CMD ["node", "server.js"]
DOCKERFILE
fi

# 修改 .dockerignore 允许 .next
sed -i 's/^\.next$/#.next/' .dockerignore 2>/dev/null || true
sed -i 's/^node_modules$/\/node_modules/' .dockerignore 2>/dev/null || true

# 构建 Docker 镜像
echo -e "${BLUE}构建 Docker 镜像...${NC}"
docker build -f deploy/Dockerfile.minimal -t claude-app .
echo -e "${GREEN}✓ 镜像构建完成${NC}"

# 启动 PostgreSQL 和 Redis
echo -e "${BLUE}启动数据库和 Redis...${NC}"

# 创建 docker network（如果不存在）
docker network create claude-api-gateway_default 2>/dev/null || true

# 启动 PostgreSQL
docker rm -f claude-code-hub-db 2>/dev/null || true
docker run -d --name claude-code-hub-db \
    --network claude-api-gateway_default \
    -p 127.0.0.1:35432:5432 \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_PASSWORD=$(grep "^DB_PASSWORD=" .env | cut -d'=' -f2) \
    -e POSTGRES_DB=claude_code_hub \
    -e PGDATA=/data/pgdata \
    -e TZ=Asia/Shanghai \
    -v $(pwd)/data/postgres:/data \
    --restart unless-stopped \
    docker.1ms.run/library/postgres:17

# 启动 Redis
docker rm -f claude-code-hub-redis 2>/dev/null || true
docker run -d --name claude-code-hub-redis \
    --network claude-api-gateway_default \
    -p 127.0.0.1:36379:6379 \
    -v $(pwd)/data/redis:/data \
    --restart unless-stopped \
    docker.1ms.run/library/redis:7-alpine redis-server --appendonly yes

echo -e "${GREEN}✓ 数据库和 Redis 已启动${NC}"

# 等待数据库就绪
echo -e "${BLUE}等待数据库就绪...${NC}"
sleep 15

# 启动应用
echo -e "${BLUE}启动应用...${NC}"
DB_PWD=$(grep "^DB_PASSWORD=" .env | cut -d'=' -f2)
docker rm -f claude-code-hub-app 2>/dev/null || true
docker run -d --name claude-code-hub-app \
    --network claude-api-gateway_default \
    -p 127.0.0.1:${APP_PORT}:3000 \
    --env-file .env \
    -e DSN="postgresql://postgres:${DB_PWD}@claude-code-hub-db:5432/claude_code_hub" \
    -e REDIS_URL="redis://claude-code-hub-redis:6379" \
    -e AUTO_MIGRATE=true \
    --restart unless-stopped \
    claude-app

echo -e "${GREEN}✓ 应用已启动${NC}"

# 等待应用启动
sleep 10

# 检查应用状态
if docker ps | grep -q claude-code-hub-app; then
    echo -e "${GREEN}✓ 应用运行正常${NC}"
else
    echo -e "${RED}应用启动失败，查看日志:${NC}"
    docker logs claude-code-hub-app
    exit 1
fi

# 安装和配置 Nginx
echo -e "${BLUE}配置 Nginx...${NC}"

if ! command -v nginx &> /dev/null; then
    echo -e "${YELLOW}安装 Nginx...${NC}"
    yum install -y nginx || apt-get install -y nginx
fi

systemctl enable nginx

# 创建 Nginx 配置
cat > /etc/nginx/conf.d/claude-api-gateway.conf << EOF
server {
    listen 80;
    server_name ${DOMAIN};

    # 用于 Let's Encrypt 验证
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;

        # SSE 支持
        proxy_set_header Accept-Encoding "";
        chunked_transfer_encoding on;
    }
}
EOF

# 测试 Nginx 配置
nginx -t
systemctl restart nginx
echo -e "${GREEN}✓ Nginx 配置完成${NC}"

# 配置 HTTPS
echo -e "${BLUE}配置 HTTPS 证书...${NC}"

if ! command -v certbot &> /dev/null; then
    echo -e "${YELLOW}安装 Certbot...${NC}"
    yum install -y certbot 2>/dev/null || apt-get install -y certbot
fi

# 停止 Nginx 以释放 80 端口
/usr/sbin/nginx -s stop 2>/dev/null || true
sleep 2

# 使用 standalone 模式申请证书（避免 nginx 插件问题）
echo -e "${YELLOW}申请 Let's Encrypt 证书...${NC}"
CERT_DIR="/tmp/letsencrypt"
mkdir -p ${CERT_DIR}

certbot certonly --standalone -d ${DOMAIN} \
    --config-dir ${CERT_DIR} \
    --work-dir ${CERT_DIR} \
    --logs-dir ${CERT_DIR} \
    --non-interactive --agree-tos --email admin@${DOMAIN} || {
    echo -e "${YELLOW}自动申请失败，请手动运行:${NC}"
    echo "certbot certonly --standalone -d ${DOMAIN} --config-dir /tmp/letsencrypt --work-dir /tmp/letsencrypt --logs-dir /tmp/letsencrypt"
    # 如果证书申请失败，使用 HTTP 配置
    cat > /etc/nginx/conf.d/claude-api-gateway.conf << NGINX_HTTP
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;
    }
}
NGINX_HTTP
    /usr/sbin/nginx
    echo -e "${YELLOW}已配置 HTTP 访问，请稍后手动配置 HTTPS${NC}"
}

# 如果证书申请成功，配置 HTTPS
if [ -f "${CERT_DIR}/live/${DOMAIN}/fullchain.pem" ]; then
    echo -e "${GREEN}✓ 证书申请成功${NC}"

    # 配置 Nginx HTTPS
    cat > /etc/nginx/conf.d/claude-api-gateway.conf << NGINX_HTTPS
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate ${CERT_DIR}/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/live/${DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;
    }
}
NGINX_HTTPS

    # 直接启动 nginx（避免 systemd 问题）
    /usr/sbin/nginx
    echo -e "${GREEN}✓ HTTPS 配置完成${NC}"

    # 设置证书自动续期
    cat > /etc/cron.d/certbot-renew << CRON
0 0,12 * * * root certbot renew --config-dir ${CERT_DIR} --work-dir ${CERT_DIR} --logs-dir ${CERT_DIR} --quiet --post-hook "/usr/sbin/nginx -s reload"
CRON
    echo -e "${GREEN}✓ 证书自动续期已配置${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  部署完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "访问地址: ${BLUE}https://${DOMAIN}${NC}"
echo -e "管理后台: ${BLUE}https://${DOMAIN}${NC}"
echo -e "API 文档: ${BLUE}https://${DOMAIN}/api/actions/scalar${NC}"
echo ""
echo -e "${YELLOW}常用命令:${NC}"
echo "  查看应用日志: docker logs -f claude-code-hub-app"
echo "  查看数据库日志: docker logs -f claude-code-hub-db"
echo "  重启应用: docker restart claude-code-hub-app"
echo "  停止所有: docker stop claude-code-hub-app claude-code-hub-db claude-code-hub-redis"
echo ""
echo -e "${YELLOW}如果 HTTPS 未生效，请手动运行:${NC}"
echo "  certbot --nginx -d ${DOMAIN}"
echo ""
