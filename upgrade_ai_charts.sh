#!/bin/bash
set -e

BASE=~/osint-system

echo "========== 1. 升级数据库字段 =========="
sudo docker compose exec -T postgres psql -U osint -d osintdb <<'SQL'
ALTER TABLE news ADD COLUMN IF NOT EXISTS ai_summary TEXT;
ALTER TABLE news ADD COLUMN IF NOT EXISTS risk_level TEXT;
SQL

echo "========== 2. 升级 analyzer =========="
cat > $BASE/analyzer/analyzer.py <<'PY'
import redis, json, os, psycopg2, time, re

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
    ts BIGINT,
    ai_summary TEXT,
    risk_level TEXT
)
""")

cur.execute("ALTER TABLE news ADD COLUMN IF NOT EXISTS ai_summary TEXT")
cur.execute("ALTER TABLE news ADD COLUMN IF NOT EXISTS risk_level TEXT")

KEYWORDS = {
    "AI": ["AI", "artificial intelligence", "LLM", "OpenAI", "ChatGPT", "model", "GPU", "Claude"],
    "芯片": ["chip", "semiconductor", "NVIDIA", "AMD", "Intel", "ARM", "RISC-V", "GPU"],
    "网络安全": ["security", "hack", "malware", "CVE", "ransomware", "漏洞", "攻击"],
    "国际": ["China", "US", "Russia", "Europe", "war", "trade", "Trump"],
    "技术": ["Linux", "Docker", "Python", "Kubernetes", "open source", "FreeBSD"]
}

def clean_text(text):
    text = re.sub(r"<.*?>", "", text)
    text = text.replace("\n", " ").replace("\r", " ")
    return text.strip()

def analyze_category(text):
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

def risk_level(score):
    if score >= 30:
        return "高"
    elif score >= 10:
        return "中"
    return "低"

def local_ai_summary(title, summary, category, score):
    text = clean_text(summary)
    if len(text) > 180:
        text = text[:180] + "..."

    if not text:
        text = title

    level = risk_level(score)

    return f"【AI摘要】该信息来源于公开渠道，主题为「{category}」，当前评估为{level}关注级别。核心内容：{text}"

print("analyzer started with AI summary", flush=True)

while True:
    data = r.brpop("news", timeout=5)
    if not data:
        continue

    item = json.loads(data[1])

    title = clean_text(item.get("title",""))
    summary = clean_text(item.get("summary",""))
    text = title + " " + summary

    category, score = analyze_category(text)
    level = risk_level(score)
    ai_summary = local_ai_summary(title, summary, category, score)

    cur.execute("""
    INSERT INTO news (id, source, title, summary, link, category, score, ts, ai_summary, risk_level)
    VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
    ON CONFLICT (id) DO UPDATE SET
        source = EXCLUDED.source,
        title = EXCLUDED.title,
        summary = EXCLUDED.summary,
        link = EXCLUDED.link,
        category = EXCLUDED.category,
        score = EXCLUDED.score,
        ts = EXCLUDED.ts,
        ai_summary = EXCLUDED.ai_summary,
        risk_level = EXCLUDED.risk_level
    """, (
        item["id"],
        item.get("source","unknown"),
        title,
        summary,
        item.get("link",""),
        category,
        score,
        item.get("ts", int(time.time())),
        ai_summary,
        level
    ))

    print("saved:", title, category, score, level, flush=True)
PY

echo "========== 3. 升级 API + 图表页面 =========="
cat > $BASE/api/app.py <<'PY'
from fastapi import FastAPI
from fastapi.responses import HTMLResponse
import psycopg2, time
from collections import Counter

app = FastAPI()

def conn():
    return psycopg2.connect(
        host="postgres",
        user="osint",
        password="osint123",
        dbname="osintdb"
    )

def fetch_news():
    c = conn()
    cur = c.cursor()
    cur.execute("""
        SELECT source,title,summary,link,category,score,ts,ai_summary,risk_level
        FROM news
        ORDER BY ts DESC
        LIMIT 200
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
            "category": r[4] or "其他",
            "score": r[5] or 0,
            "time": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(r[6])),
            "ai_summary": r[7] or "",
            "risk_level": r[8] or "低"
        }
        for r in rows
    ]

@app.get("/api/news")
def api_news():
    return fetch_news()

@app.get("/api/stats")
def api_stats():
    data = fetch_news()

    category_counter = Counter()
    source_counter = Counter()
    risk_counter = Counter()

    for x in data:
        for c in x["category"].split(","):
            category_counter[c] += 1
        source_counter[x["source"]] += 1
        risk_counter[x["risk_level"]] += 1

    return {
        "total": len(data),
        "ai_chip": sum(1 for x in data if "AI" in x["category"] or "芯片" in x["category"]),
        "security": sum(1 for x in data if "网络安全" in x["category"]),
        "high": sum(1 for x in data if x["score"] >= 10),
        "categories": dict(category_counter),
        "sources": dict(source_counter),
        "risks": dict(risk_counter)
    }

@app.get("/", response_class=HTMLResponse)
def index():
    return """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>AI + 图表 OSINT 情报分析系统</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<style>
body{font-family:Arial;margin:0;background:#111827;color:#e5e7eb}
.header{padding:28px;background:#020617;border-bottom:1px solid #334155}
h1{margin:0;font-size:34px}
.sub{color:#93c5fd;margin-top:10px}
.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;padding:20px}
.card{background:#1f2937;padding:18px;border-radius:14px}
.num{font-size:30px;font-weight:bold;color:#38bdf8}
.charts{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;padding:0 20px 20px}
.chart-card{background:#1f2937;padding:18px;border-radius:14px;height:320px}
.list{padding:20px}
.item{background:#1f2937;margin-bottom:14px;padding:18px;border-radius:14px;border-left:5px solid #38bdf8}
.item.high{border-left-color:#ef4444}
.item.mid{border-left-color:#f97316}
.meta{color:#94a3b8;font-size:13px;margin:8px 0}
.score{color:#f97316;font-weight:bold}
.cat{color:#22c55e;font-weight:bold}
.ai{background:#0f172a;border-radius:10px;padding:12px;margin-top:12px;color:#bfdbfe}
a{color:#93c5fd;text-decoration:none}
.summary{color:#cbd5e1}
.toolbar{padding:0 20px 20px}
input,select{background:#020617;color:#e5e7eb;border:1px solid #334155;border-radius:8px;padding:10px;margin-right:8px}
</style>
</head>
<body>
<div class="header">
<h1>AI + 图表 OSINT 情报分析系统</h1>
<div class="sub">公开信息采集 / AI摘要 / 分类统计 / 情报评分 / 自动刷新</div>
</div>

<div class="grid">
<div class="card">总数量<div id="total" class="num">0</div></div>
<div class="card">AI/芯片<div id="tech" class="num">0</div></div>
<div class="card">安全情报<div id="sec" class="num">0</div></div>
<div class="card">中高分情报<div id="high" class="num">0</div></div>
</div>

<div class="charts">
<div class="chart-card"><canvas id="catChart"></canvas></div>
<div class="chart-card"><canvas id="sourceChart"></canvas></div>
<div class="chart-card"><canvas id="riskChart"></canvas></div>
</div>

<div class="toolbar">
<input id="kw" placeholder="搜索标题/摘要/AI摘要" oninput="renderList()">
<select id="riskFilter" onchange="renderList()">
<option value="">全部风险</option>
<option value="高">高</option>
<option value="中">中</option>
<option value="低">低</option>
</select>
</div>

<div class="list" id="list"></div>

<script>
let allData = [];
let charts = {};

function makeChart(id, title, labels, values){
    if(charts[id]) charts[id].destroy();
    const ctx = document.getElementById(id);
    charts[id] = new Chart(ctx, {
        type: 'bar',
        data: {
            labels: labels,
            datasets: [{ label: title, data: values }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
                legend: { labels: { color: '#e5e7eb' } },
                title: { display: true, text: title, color: '#e5e7eb' }
            },
            scales: {
                x: { ticks: { color: '#cbd5e1' } },
                y: { ticks: { color: '#cbd5e1' } }
            }
        }
    });
}

async function loadStats(){
    const res = await fetch('/api/stats');
    const s = await res.json();

    document.getElementById('total').innerText = s.total;
    document.getElementById('tech').innerText = s.ai_chip;
    document.getElementById('sec').innerText = s.security;
    document.getElementById('high').innerText = s.high;

    makeChart('catChart', '分类统计', Object.keys(s.categories), Object.values(s.categories));
    makeChart('sourceChart', '来源统计', Object.keys(s.sources), Object.values(s.sources));
    makeChart('riskChart', '风险等级', Object.keys(s.risks), Object.values(s.risks));
}

async function loadNews(){
    const res = await fetch('/api/news');
    allData = await res.json();
    renderList();
}

function renderList(){
    const kw = document.getElementById('kw').value.toLowerCase();
    const risk = document.getElementById('riskFilter').value;

    let data = allData.filter(x => {
        const text = `${x.title} ${x.summary} ${x.ai_summary}`.toLowerCase();
        const okKw = !kw || text.includes(kw);
        const okRisk = !risk || x.risk_level === risk;
        return okKw && okRisk;
    });

    const list = document.getElementById('list');
    list.innerHTML = '';

    if(data.length === 0){
        list.innerHTML = '<div class="item">暂无匹配数据。</div>';
        return;
    }

    data.forEach(x=>{
        const div = document.createElement('div');
        div.className = 'item ' + (x.risk_level === '高' ? 'high' : (x.risk_level === '中' ? 'mid' : ''));
        div.innerHTML = `
            <h3><a href="${x.link}" target="_blank">${x.title}</a></h3>
            <div class="meta">
                来源：${x.source} ｜ 时间：${x.time} ｜
                分类：<span class="cat">${x.category}</span> ｜
                情报分：<span class="score">${x.score}</span> ｜
                风险：<span class="score">${x.risk_level}</span>
            </div>
            <div class="summary">${x.summary || ''}</div>
            <div class="ai">${x.ai_summary || '暂无AI摘要'}</div>
        `;
        list.appendChild(div);
    });
}

async function refresh(){
    await loadStats();
    await loadNews();
}

setInterval(refresh, 8000);
refresh();
</script>
</body>
</html>
"""
PY

echo "========== 4. 重建并重启 =========="
cd $BASE
sudo docker compose build --no-cache api analyzer
sudo docker compose up -d api analyzer crawler

echo "========== 5. 重启采集与分析 =========="
sudo docker compose restart crawler analyzer api

echo "========== 6. 当前状态 =========="
sudo docker compose ps

echo "========== 升级完成 =========="
echo "访问：http://你的Ubuntu_IP:7000"
