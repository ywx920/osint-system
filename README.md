# 🚀 AI + 图表 OSINT 情报分析系统

一个基于 **Docker + 本地大模型（Ollama）+ 多源RSS** 构建的
👉 实时情报采集、分析、可视化系统

---

# 🧠 项目功能

## ✅ 核心能力

* 🌐 多源新闻采集（国内 + 国外）
* 🧠 AI 自动分析（本地大模型）
* 🏷️ 自动分类（AI / 芯片 / 安全 / 国际等）
* ⚠️ 风险评估（低 / 中 / 高）
* 📊 数据可视化（分类 / 来源 / 风险）
* 🔎 搜索 + 筛选
* 🔄 实时刷新

---

## 🤖 AI结构化输出

系统自动生成：

```json
{
  "summary": "一句话摘要",
  "impact": "可能影响",
  "risk": "低/中/高",
  "action": "建议动作"
}
```

---

# 🏗️ 系统架构

```text
crawler   → 采集RSS
    ↓
redis     → 消息队列
    ↓
analyzer  → AI分析（Ollama）
    ↓
postgres  → 数据存储
    ↓
api       → 页面展示（FastAPI）
```

---

# 🧰 技术栈

| 类型  | 技术                      |
| --- | ----------------------- |
| 容器  | Docker / Docker Compose |
| 后端  | Python / FastAPI        |
| 数据  | Redis + PostgreSQL      |
| AI  | Ollama（本地大模型）           |
| 前端  | HTML + Chart.js         |
| 数据源 | RSS Feed                |

---

# ⚙️ 环境要求

```text
Ubuntu 22.04 / 24.04
Docker
Docker Compose
（推荐）NVIDIA GPU
```

---

# 🚀 一键启动

```bash
git clone https://github.com/ywx920/osint-system.git
cd osint-system

sudo docker compose build
sudo docker compose up -d
```

---

# 🌐 访问系统

```text
http://你的IP:7000
```

---

# 🧠 本地大模型接入（Ollama）

## 1️⃣ 安装

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

---

## 2️⃣ 启动服务

```bash
ollama serve
```

---

## 3️⃣ 拉取模型

```bash
ollama pull qwen2.5:7b
```

---

## 4️⃣ 修改监听地址（关键）

```bash
sudo systemctl edit ollama
```

写入：

```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
```

应用：

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

---

# 📰 新闻源配置

文件：

```bash
crawler/crawler.py
```

示例：

```python
SOURCES = [
    ("Hacker News", "https://hnrss.org/frontpage"),
    ("36氪", "https://36kr.com/feed"),
]
```

---

## 🔄 修改后生效

```bash
sudo docker compose restart crawler
```

---

# ⏱️ 刷新频率

```python
time.sleep(60)
```

单位：秒

---

# 🛠️ 常见问题

---

## ❗ Docker 无法拉镜像

编辑：

```bash
/etc/docker/daemon.json
```

添加：

```json
{
  "registry-mirrors": ["https://docker.m.daocloud.io"]
}
```

---

## ❗ GitHub push 失败

使用 SSH：

```bash
ssh-keygen -t ed25519
git remote set-url origin git@github.com:ywx920/osint-system.git
git push
```

---

## ❗ AI 调用失败

检查：

```bash
ss -lntp | grep 11434
```

---

## ❗ analyzer 报错缺少 requests

```text
ModuleNotFoundError: requests
```

👉 在 requirements.txt 添加：

```text
requests
```

---

# 📊 当前能力

```text
✔ 实时数据采集
✔ AI分析
✔ 风险评估
✔ 可视化
✔ 多源融合
```

---

# 🚀 后续规划

* [ ] 🚨 告警系统（高风险自动提示）
* [ ] 📈 趋势分析（热点检测）
* [ ] 🧠 事件聚类
* [ ] 🔔 Webhook/通知
* [ ] 🌍 分布式采集

---

# 👨‍💻 作者

wx-osint

---

# ⭐ 项目意义

```text
本项目用于学习：
✔ AI工程
✔ Linux系统
✔ Docker部署
✔ 数据流设计
✔ 本地大模型应用
```

---

# 📌 License

MIT
