#!/bin/bash
# Claude API Gateway 管理脚本
# 域名: shop.fixingqi.store

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置
DOMAIN="shop.fixingqi.store"
APP_PORT="23000"
PROJECT_DIR="/www/claude-api-gateway"
CERT_DIR="/tmp/letsencrypt"

# 生成随机字符串
generate_random_string() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "${1:-32}" | head -n 1
}

# 显示菜单
show_menu() {
    clear
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  Claude API Gateway 管理工具${NC}"
    echo -e "${CYAN}  域名: ${DOMAIN}${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} 安装部署（完整安装）"
    echo -e "${GREEN}2.${NC} 启动服务"
    echo -e "${GREEN}3.${NC} 停止服务"
    echo -e "${GREEN}4.${NC} 重启服务"
    echo -e "${GREEN}5.${NC} 查看状态"
    echo -e "${GREEN}6.${NC} 查看日志"
    echo -e "${GREEN}7.${NC} 卸载清理"
    echo -e "${GREEN}8.${NC} 更新部署（保留数据）"
    echo -e "${GREEN}9.${NC} 申请/续期 HTTPS 证书"
    echo -e "${GREEN}0.${NC} 退出"
    echo ""
    echo -e "${YELLOW}请输入选项 [0-9]:${NC} "
}

# 检查 Docker
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}安装 Docker...${NC}"
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    fi
}

# 1. 安装部署
install_deploy() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  开始完整安装部署${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # 检查项目目录
    if [ ! -d "${PROJECT_DIR}" ] || [ ! -d "${PROJECT_DIR}/.next" ]; then
        echo -e "${RED}错误: 项目目录不存在或 .next 目录缺失${NC}"
        echo "请先上传项目到 ${PROJECT_DIR}"
        return 1
    fi

    cd ${PROJECT_DIR}

    # 检查 Docker
    check_docker
    echo -e "${GREEN}✓ Docker 已安装${NC}"

    # 创建 .env 文件
    if [ ! -f ".env" ]; then
        echo -e "${YELLOW}创建 .env 配置文件...${NC}"

        ADMIN_TOKEN=$(generate_random_string 32)
        DB_PASSWORD=$(generate_random_string 24)

        cat > .env << EOF
ADMIN_TOKEN=${ADMIN_TOKEN}
DB_USER=postgres
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=claude_code_hub
APP_PORT=${APP_PORT}
APP_URL=https://${DOMAIN}
AUTO_MIGRATE=true
ENABLE_SECURE_COOKIES=true
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
    docker rm -f claude-code-hub-app claude-code-hub-db claude-code-hub-redis 2>/dev/null || true

    # 创建 Dockerfile.minimal
    mkdir -p deploy
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

    # 修改 .dockerignore
    sed -i 's/^\.next$/#.next/' .dockerignore 2>/dev/null || true
    sed -i 's/^node_modules$/\/node_modules/' .dockerignore 2>/dev/null || true

    # 构建镜像
    echo -e "${BLUE}构建 Docker 镜像...${NC}"
    docker build -f deploy/Dockerfile.minimal -t claude-app .
    echo -e "${GREEN}✓ 镜像构建完成${NC}"

    # 创建网络
    docker network create claude-api-gateway_default 2>/dev/null || true

    # 启动 PostgreSQL
    echo -e "${BLUE}启动 PostgreSQL...${NC}"
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
    echo -e "${BLUE}启动 Redis...${NC}"
    docker rm -f claude-code-hub-redis 2>/dev/null || true
    docker run -d --name claude-code-hub-redis \
        --network claude-api-gateway_default \
        -p 127.0.0.1:36379:6379 \
        -v $(pwd)/data/redis:/data \
        --restart unless-stopped \
        docker.1ms.run/library/redis:7-alpine redis-server --appendonly yes

    echo -e "${GREEN}✓ 数据库和 Redis 已启动${NC}"

    # 等待数据库
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
    sleep 5

    # 安装 Nginx
    if ! command -v nginx &> /dev/null; then
        echo -e "${YELLOW}安装 Nginx...${NC}"
        yum install -y nginx 2>/dev/null || apt-get install -y nginx
    fi

    # 配置 Nginx（先用 HTTP）
    cat > /etc/nginx/conf.d/claude-api-gateway.conf << EOF
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
EOF

    # 删除冲突配置
    rm -f /etc/nginx/conf.d/chatgpt.conf 2>/dev/null

    # 启动 Nginx
    /usr/sbin/nginx -s stop 2>/dev/null || true
    sleep 1
    /usr/sbin/nginx
    echo -e "${GREEN}✓ Nginx 已启动${NC}"

    # 申请 HTTPS 证书
    setup_https

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  安装完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "访问地址: ${BLUE}https://${DOMAIN}${NC}"
    echo -e "管理员令牌: ${BLUE}$(grep ADMIN_TOKEN .env | cut -d'=' -f2)${NC}"
    echo ""
}

# 2. 启动服务
start_services() {
    echo -e "${BLUE}启动服务...${NC}"
    docker start claude-code-hub-db claude-code-hub-redis claude-code-hub-app 2>/dev/null || {
        echo -e "${RED}启动失败，请先执行安装${NC}"
        return 1
    }
    /usr/sbin/nginx 2>/dev/null || true
    echo -e "${GREEN}✓ 服务已启动${NC}"
}

# 3. 停止服务
stop_services() {
    echo -e "${BLUE}停止服务...${NC}"
    docker stop claude-code-hub-app claude-code-hub-db claude-code-hub-redis 2>/dev/null || true
    /usr/sbin/nginx -s stop 2>/dev/null || true
    echo -e "${GREEN}✓ 服务已停止${NC}"
}

# 4. 重启服务
restart_services() {
    echo -e "${BLUE}重启服务...${NC}"
    docker restart claude-code-hub-db claude-code-hub-redis claude-code-hub-app 2>/dev/null || {
        echo -e "${RED}重启失败${NC}"
        return 1
    }
    /usr/sbin/nginx -s reload 2>/dev/null || /usr/sbin/nginx
    echo -e "${GREEN}✓ 服务已重启${NC}"
}

# 5. 查看状态
show_status() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  服务状态${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    echo -e "${CYAN}Docker 容器:${NC}"
    docker ps -a --filter "name=claude-code-hub" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""

    echo -e "${CYAN}Nginx 状态:${NC}"
    if pgrep nginx > /dev/null; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
    echo ""

    echo -e "${CYAN}健康检查:${NC}"
    if curl -s http://127.0.0.1:${APP_PORT}/api/actions/health > /dev/null 2>&1; then
        echo -e "${GREEN}应用正常响应${NC}"
    else
        echo -e "${RED}应用无响应${NC}"
    fi
    echo ""

    echo -e "${CYAN}访问地址:${NC}"
    echo -e "  HTTP:  http://${DOMAIN}"
    echo -e "  HTTPS: https://${DOMAIN}"
    echo ""

    if [ -f "${PROJECT_DIR}/.env" ]; then
        echo -e "${CYAN}管理员令牌:${NC}"
        grep ADMIN_TOKEN ${PROJECT_DIR}/.env | cut -d'=' -f2
    fi
    echo ""
}

# 6. 查看日志
show_logs() {
    echo -e "${BLUE}选择要查看的日志:${NC}"
    echo "1. 应用日志"
    echo "2. 数据库日志"
    echo "3. Redis 日志"
    echo "4. Nginx 错误日志"
    read -p "请选择 [1-4]: " log_choice

    case $log_choice in
        1) docker logs -f --tail 100 claude-code-hub-app ;;
        2) docker logs -f --tail 100 claude-code-hub-db ;;
        3) docker logs -f --tail 100 claude-code-hub-redis ;;
        4) tail -f /var/log/nginx/error.log ;;
        *) echo "无效选项" ;;
    esac
}

# 7. 卸载清理
uninstall() {
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}  警告：即将卸载所有服务${NC}"
    echo -e "${RED}========================================${NC}"
    echo ""
    read -p "是否保留数据库数据？[y/N]: " keep_data
    read -p "确认卸载？[y/N]: " confirm

    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "取消卸载"
        return
    fi

    echo -e "${BLUE}停止并删除容器...${NC}"
    docker rm -f claude-code-hub-app claude-code-hub-db claude-code-hub-redis 2>/dev/null || true

    echo -e "${BLUE}删除 Docker 网络...${NC}"
    docker network rm claude-api-gateway_default 2>/dev/null || true

    echo -e "${BLUE}停止 Nginx...${NC}"
    /usr/sbin/nginx -s stop 2>/dev/null || true

    echo -e "${BLUE}删除 Nginx 配置...${NC}"
    rm -f /etc/nginx/conf.d/claude-api-gateway.conf

    echo -e "${BLUE}删除证书...${NC}"
    rm -rf ${CERT_DIR}

    if [ "$keep_data" != "y" ] && [ "$keep_data" != "Y" ]; then
        echo -e "${BLUE}删除数据目录...${NC}"
        rm -rf ${PROJECT_DIR}/data
    fi

    echo -e "${BLUE}清理 Docker 缓存...${NC}"
    docker system prune -f

    echo -e "${GREEN}✓ 卸载完成${NC}"
}

# 8. 更新部署
update_deploy() {
    echo -e "${BLUE}更新部署（保留数据）...${NC}"

    cd ${PROJECT_DIR}

    # 停止应用
    docker stop claude-code-hub-app 2>/dev/null || true

    # 重新构建镜像
    echo -e "${BLUE}重新构建镜像...${NC}"
    docker build -f deploy/Dockerfile.minimal -t claude-app .

    # 启动应用
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

    echo -e "${GREEN}✓ 更新完成${NC}"
}

# 9. 申请 HTTPS 证书
setup_https() {
    echo -e "${BLUE}配置 HTTPS 证书...${NC}"

    # 安装 certbot
    if ! command -v certbot &> /dev/null; then
        echo -e "${YELLOW}安装 Certbot...${NC}"
        yum install -y certbot 2>/dev/null || apt-get install -y certbot
    fi

    # 停止 Nginx
    /usr/sbin/nginx -s stop 2>/dev/null || true
    sleep 2

    # 申请证书
    mkdir -p ${CERT_DIR}
    certbot certonly --standalone -d ${DOMAIN} \
        --config-dir ${CERT_DIR} \
        --work-dir ${CERT_DIR} \
        --logs-dir ${CERT_DIR} \
        --non-interactive --agree-tos --email admin@${DOMAIN} 2>/dev/null || {
        echo -e "${YELLOW}自动申请失败，尝试交互式申请...${NC}"
        certbot certonly --standalone -d ${DOMAIN} \
            --config-dir ${CERT_DIR} \
            --work-dir ${CERT_DIR} \
            --logs-dir ${CERT_DIR}
    }

    # 配置 HTTPS
    if [ -f "${CERT_DIR}/live/${DOMAIN}/fullchain.pem" ]; then
        echo -e "${GREEN}✓ 证书申请成功${NC}"

        cat > /etc/nginx/conf.d/claude-api-gateway.conf << EOF
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
EOF
        echo -e "${GREEN}✓ HTTPS 配置完成${NC}"
    else
        echo -e "${YELLOW}证书申请失败，保持 HTTP 配置${NC}"
    fi

    # 启动 Nginx
    /usr/sbin/nginx
    echo -e "${GREEN}✓ Nginx 已启动${NC}"
}

# 主循环
main() {
    while true; do
        show_menu
        read choice

        case $choice in
            1) install_deploy ;;
            2) start_services ;;
            3) stop_services ;;
            4) restart_services ;;
            5) show_status ;;
            6) show_logs ;;
            7) uninstall ;;
            8) update_deploy ;;
            9) setup_https ;;
            0) echo "退出"; exit 0 ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac

        echo ""
        read -p "按回车键继续..."
    done
}

# 支持命令行参数
if [ $# -gt 0 ]; then
    case $1 in
        install) install_deploy ;;
        start) start_services ;;
        stop) stop_services ;;
        restart) restart_services ;;
        status) show_status ;;
        logs) show_logs ;;
        uninstall) uninstall ;;
        update) update_deploy ;;
        https) setup_https ;;
        *) echo "用法: $0 {install|start|stop|restart|status|logs|uninstall|update|https}" ;;
    esac
else
    main
fi
