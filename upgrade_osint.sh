#!/bin/bash
set -e

BASE=~/osint-system

echo "========== 1. 升级 crawler =========="
cat > $BASE/crawler/crawler.py <<'PY'
import time, redis, feedparser, json, os, hashlib

r = redis.Redis(host=os.environ.get("REDIS_HOST","redis"), decode_responses=True)

SOURCES = [
    ("BBC World", "https://feeds.bbci.co.uk/news/world/rss.xml"),
    ("Hacker News", "https://hnrss.org/frontpage"),
    ("The Hacker News", "https://feeds.feedburner.com/TheHackersNews"),
    ("Solidot", "https://www.solidot.org/index.rss"),
]

def make_id(title, link):
    return hashlib.md5((title + link).encode("utf-8")).hexdigest()

while True:
    for name, url in SOURCES:
        try:
            feed = feedparser.parse(url)
            print("fetch:", name, "entries:", len(feed.entries), flush=True)

            for e in feed.entries[:10]:
                title = e.get("title", "")
                link = e.get("link", "")
                summary = e.get("summary", "")

                if not title:
                    continue

                item = {
                    "id": make_id(title, link),
                    "source": name,
                    "title": title,
                    "summary": summary,
                    "link": link,
                    "ts": int(time.time())
                }

                r.lpush("news", json.dumps(item, ensure_ascii=False))
                print("push:", title, flush=True)

        except Exception as ex:
            print("crawler error:", name, ex, flush=True)

    time.sleep(60)
PY

echo "========== 2. 升级 analyzer =========="
cat > $BASE/analyzer/analyzer.py <<'PY'
import redis, json, os, psycopg2, time

r = redis.Redis(host=os.environ.get("REDIS_HOST","redis"), decode_responses=True)

conn = psycopg2.connect(
    host=os.environ.get("PG_HOST"),
    user=os.environ.get("PG_USER"),
    password=os.environ.get("PG_PASSWORD"),
    dbname=os.environ.get("PG_DB")
)
conn.autocommit = True
cur = conn.cursor()

cur.execute("""
CREATE TABLE IF NOT EXISTS news (
    id TEXT PRIMARY KEY,
    source TEXT,
    title TEXT,
    summary TEXT,
    link TEXT,
    category TEXT,
    score INTEGER,
    ts BIGINT
)
""")

KEYWORDS = {
    "AI": ["AI", "artificial intelligence", "LLM", "OpenAI", "ChatGPT", "model", "GPU"],
    "芯片": ["chip", "semiconductor", "NVIDIA", "AMD", "Intel", "ARM", "RISC-V"],
    "网络安全": ["security", "hack", "malware", "CVE", "ransomware", "漏洞", "攻击"],
    "国际": ["China", "US", "Russia", "Europe", "war", "trade"],
    "技术": ["Linux", "Docker", "Python", "Kubernetes", "open source"]
}

def analyze(text):
    cats = []
    score = 0
    lower = text.lower()

    for cat, words in KEYWORDS.items():
        for w in words:
            if w.lower() in lower:
                cats.append(cat)
                score += 10
                break

    if not cats:
        return "其他", 1

    return ",".join(cats), score

print("analyzer started", flush=True)

while True:
    data = r.brpop("news", timeout=5)
    if not data:
        continue

    item = json.loads(data[1])
    text = item.get("title","") + " " + item.get("summary","")
    category, score = analyze(text)

    cur.execute("""
    INSERT INTO news (id, source, title, summary, link, category, score, ts)
    VALUES (%s,%s,%s,%s,%s,%s,%s,%s)
    ON CONFLICT (id) DO NOTHING
    """, (
        item["id"],
        item.get("source","unknown"),
        item.get("title",""),
        item.get("summary",""),
        item.get("link",""),
        category,
        score,
        item.get("ts", int(time.time()))
    ))

    print("saved:", item.get("title",""), category, score, flush=True)
PY

echo "========== 3. 升级 API 页面 =========="
cat > $BASE/api/app.py <<'PY'
from fastapi import FastAPI
from fastapi.responses import HTMLResponse
import psycopg2, time

app = FastAPI()

def conn():
    return psycopg2.connect(
        host="postgres",
        user="osint",
        password="osint123",
        dbname="osintdb"
    )

@app.get("/api/news")
def api_news():
    c = conn()
    cur = c.cursor()
    cur.execute("""
        SELECT source,title,summary,link,category,score,ts
        FROM news
        ORDER BY ts DESC
        LIMIT 100
    """)
    rows = cur.fetchall()
    cur.close()
    c.close()

    return [
        {
            "source": r[0],
            "title": r[1],
            "summary": r[2],
            "link": r[3],
            "category": r[4],
            "score": r[5],
            "time": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(r[6]))
        }
        for r in rows
    ]

@app.get("/", response_class=HTMLResponse)
def index():
    return """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>实时情报分析系统</title>
<style>
body{font-family:Arial;margin:0;background:#111827;color:#e5e7eb}
.header{padding:24px;background:#020617;border-bottom:1px solid #334155}
h1{margin:0}
.sub{color:#94a3b8;margin-top:8px}
.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;padding:20px}
.card{background:#1f2937;padding:18px;border-radius:14px}
.num{font-size:28px;font-weight:bold;color:#38bdf8}
.list{padding:20px}
.item{background:#1f2937;margin-bottom:14px;padding:18px;border-radius:14px;border-left:5px solid #38bdf8}
.meta{color:#94a3b8;font-size:13px;margin:8px 0}
.score{color:#f97316;font-weight:bold}
.cat{color:#22c55e;font-weight:bold}
a{color:#93c5fd;text-decoration:none}
.summary{color:#cbd5e1}
</style>
</head>
<body>
<div class="header">
<h1>实时 OSINT 情报分析系统</h1>
<div class="sub">公开信息采集 / 关键词分类 / 情报评分 / 自动刷新</div>
</div>

<div class="grid">
<div class="card">总数量<div id="total" class="num">0</div></div>
<div class="card">AI/芯片<div id="tech" class="num">0</div></div>
<div class="card">安全情报<div id="sec" class="num">0</div></div>
<div class="card">高分情报<div id="high" class="num">0</div></div>
</div>

<div class="list" id="list"></div>

<script>
async function load(){
    const res = await fetch('/api/news');
    const data = await res.json();

    document.getElementById('total').innerText = data.length;
    document.getElementById('tech').innerText = data.filter(x => x.category.includes('AI') || x.category.includes('芯片') || x.category.includes('技术')).length;
    document.getElementById('sec').innerText = data.filter(x => x.category.includes('网络安全')).length;
    document.getElementById('high').innerText = data.filter(x => x.score >= 10).length;

    const list = document.getElementById('list');
    list.innerHTML = '';

    if(data.length === 0){
        list.innerHTML = '<div class="item">暂无数据：请检查 crawler 和 analyzer 日志。</div>';
        return;
    }

    data.forEach(x=>{
        const div = document.createElement('div');
        div.className = 'item';
        div.innerHTML = `
            <h3><a href="${x.link}" target="_blank">${x.title}</a></h3>
            <div class="meta">来源：${x.source} ｜ 时间：${x.time} ｜ 分类：<span class="cat">${x.category}</span> ｜ 情报分：<span class="score">${x.score}</span></div>
            <div class="summary">${x.summary || ''}</div>
        `;
        list.appendChild(div);
    });
}
setInterval(load, 5000);
load();
</script>
</body>
</html>
"""
PY

echo "========== 4. 重建并启动 =========="
cd $BASE
sudo docker compose build --no-cache
sudo docker compose up -d

echo "========== 5. 当前容器 =========="
sudo docker ps

echo "========== 升级完成 =========="
echo "访问：http://你的Ubuntu_IP:7000"
