#!/bin/bash

echo "============================"
echo "OSINT 系统一键修复开始"
echo "============================"

BASE=~/osint-system

# =========================
# 1. 修改 Dockerfile（换 pip 源）
# =========================
echo "[1] 修改 Dockerfile 使用阿里源..."

for dir in api analyzer crawler; do
    FILE=$BASE/$dir/Dockerfile
    if [ -f "$FILE" ]; then
        sed -i 's|pip install.*|pip install -i https://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com -r requirements.txt|' $FILE
        echo "✔ 修改 $FILE"
    else
        echo "✘ 找不到 $FILE"
    fi
done

# =========================
# 2. 修改 docker-compose.yml（加 build 网络）
# =========================
echo "[2] 修改 docker-compose.yml..."

COMPOSE_FILE=$BASE/docker-compose.yml

# 删除旧的 build 行
sed -i 's|build: ./api||g' $COMPOSE_FILE
sed -i 's|build: ./analyzer||g' $COMPOSE_FILE
sed -i 's|build: ./crawler||g' $COMPOSE_FILE

# 插入新的 build 结构
sed -i '/api:/a\    build:\n      context: ./api\n      network: host' $COMPOSE_FILE
sed -i '/analyzer:/a\    build:\n      context: ./analyzer\n      network: host' $COMPOSE_FILE
sed -i '/crawler:/a\    build:\n      context: ./crawler\n      network: host' $COMPOSE_FILE

echo "✔ docker-compose.yml 修改完成"

# =========================
# 3. 重启 Docker
# =========================
echo "[3] 重启 Docker..."
sudo systemctl restart docker

# =========================
# 4. 重新构建
# =========================
echo "[4] 重新构建镜像..."
cd $BASE || exit 1

sudo docker compose build --no-cache

# =========================
# 5. 启动系统
# =========================
echo "[5] 启动系统..."
sudo docker compose up -d

echo "============================"
echo "修复完成！"
echo "访问：http://你的IP:7000"
echo "============================"
