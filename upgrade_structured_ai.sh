#!/bin/bash
set -e

BASE=~/osint-system

echo "========== 1. 升级数据库字段 =========="
sudo docker compose exec -T postgres psql -U osint -d osintdb <<'SQL'
ALTER TABLE news ADD COLUMN IF NOT EXISTS ai_summary TEXT;
ALTER TABLE news ADD COLUMN IF NOT EXISTS ai_impact TEXT;
ALTER TABLE news ADD COLUMN IF NOT EXISTS ai_action TEXT;
ALTER TABLE news ADD COLUMN IF NOT EXISTS risk_level TEXT;
SQL

echo "========== 2. 升级 analyzer：结构化 AI 输出 =========="
cat > $BASE/analyzer/analyzer.py <<'PY'
import redis, json, os, psycopg2, time, re, requests

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
    ai_impact TEXT,
    ai_action TEXT,
    risk_level TEXT
)
""")

cur.execute("ALTER TABLE news ADD COLUMN IF NOT EXISTS ai_summary TEXT")
cur.execute("ALTER TABLE news ADD COLUMN IF NOT EXISTS ai_impact TEXT")
cur.execute("ALTER TABLE news ADD COLUMN IF NOT EXISTS ai_action TEXT")
cur.execute("ALTER TABLE news ADD COLUMN IF NOT EXISTS risk_level TEXT")

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://192.168.31.11:11434/api/generate")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen2.5:7b")

KEYWORDS = {
    "AI": ["AI", "artificial intelligence", "LLM", "OpenAI", "ChatGPT", "model", "GPU", "Claude", "Agent"],
    "芯片": ["chip", "semiconductor", "NVIDIA", "AMD", "Intel", "ARM", "RISC-V", "GPU"],
    "网络安全": ["security", "hack", "malware", "CVE", "ransomware", "漏洞", "攻击"],
    "国际": ["China", "US", "Russia", "Europe", "war", "trade", "Trump"],
    "技术": ["Linux", "Docker", "Python", "Kubernetes", "open source", "FreeBSD", "Qt"]
}

def clean_text(text):
    text = re.sub(r"<.*?>", "", text or "")
    return text.replace("\n", " ").replace("\r", " ").strip()

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

def fallback_risk(score):
    if score >= 30:
        return "高"
    elif score >= 10:
        return "中"
    return "低"

def extract_json(text):
    text = text.strip()
    try:
        return json.loads(text)
    except Exception:
        pass

    m = re.search(r"\{.*\}", text, re.S)
    if m:
        try:
            return json.loads(m.group(0))
        except Exception:
            pass

    return None

def structured_ai(title, summary, category, score):
    prompt = f"""
你是一个中文 OSINT 公开信息分析助手。
请只输出 JSON，不要输出 Markdown，不要输出解释文字。

新闻标题：
{title}

新闻摘要：
{summary}

初步分类：
{category}

关键词情报分：
{score}

请严格输出如下 JSON 格式：
{{
  "summary": "用一句话总结这条信息，控制在60字以内",
  "impact": "说明可能影响，控制在100字以内",
  "risk": "低/中/高 三选一",
  "action": "给出建议动作，控制在80字以内"
}}
"""

    try:
        resp = requests.post(
            OLLAMA_URL,
            json={
                "model": OLLAMA_MODEL,
                "prompt": prompt,
                "stream": False,
                "options": {
                    "temperature": 0.2
                }
            },
            timeout=180
        )
        resp.raise_for_status()
        raw = resp.json().get("response", "").strip()

        data = extract_json(raw)
        if not data:
            return {
                "summary": raw[:120] if raw else "AI未返回有效摘要",
                "impact": "AI输出未能解析为JSON，建议检查模型输出格式。",
                "risk": fallback_risk(score),
                "action": "查看原文并人工复核。"
            }

        return {
            "summary": str(data.get("summary", ""))[:200],
            "impact": str(data.get("impact", ""))[:300],
            "risk": data.get("risk", fallback_risk(score)) if data.get("risk") in ["低", "中", "高"] else fallback_risk(score),
            "action": str(data.get("action", ""))[:200]
        }

    except Exception as e:
        return {
            "summary": f"本地AI调用失败：{e}",
            "impact": "未能调用本地大模型生成影响分析。",
            "risk": fallback_risk(score),
            "action": "检查 Ollama 服务、模型名称和网络连通性。"
        }

print("analyzer started with structured Ollama AI", flush=True)

while True:
    data = r.brpop("news", timeout=5)
    if not data:
        continue

    item = json.loads(data[1])

    title = clean_text(item.get("title",""))
    summary = clean_text(item.get("summary",""))
    text = title + " " + summary

    category, score = analyze_category(text)
    ai = structured_ai(title, summary, category, score)

    cur.execute("""
    INSERT INTO news (
        id, source, title, summary, link, category, score, ts,
        ai_summary, ai_impact, ai_action, risk_level
    )
    VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
    ON CONFLICT (id) DO UPDATE SET
        source = EXCLUDED.source,
        title = EXCLUDED.title,
        summary = EXCLUDED.summary,
        link = EXCLUDED.link,
        category = EXCLUDED.category,
        score = EXCLUDED.score,
        ts = EXCLUDED.ts,
        ai_summary = EXCLUDED.ai_summary,
        ai_impact = EXCLUDED.ai_impact,
        ai_action = EXCLUDED.ai_action,
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
        ai["summary"],
        ai["impact"],
        ai["action"],
        ai["risk"]
    ))

    print("saved structured AI:", title, category, score, ai["risk"], flush=True)
PY

echo "========== 3. 升级 API 页面 =========="
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
        SELECT source,title,summary,link,category,score,ts,
               ai_summary, risk_level, ai_impact, ai_action
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
            "risk_level": r[8] or "低",
            "ai_impact": r[9] or "",
            "ai_action": r[10] or ""
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
        "high": sum(1 for x in data if x["risk_level"] == "高" or x["score"] >= 30),
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
<title>结构化 AI OSINT 情报分析系统</title>
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
.toolbar{padding:0 20px 20px}
input,select{background:#020617;color:#e5e7eb;border:1px solid #334155;border-radius:8px;padding:10px;margin-right:8px}
.list{padding:20px}
.item{background:#1f2937;margin-bottom:14px;padding:18px;border-radius:14px;border-left:5px solid #38bdf8}
.item.high{border-left-color:#ef4444}
.item.mid{border-left-color:#f97316}
.meta{color:#94a3b8;font-size:13px;margin:8px 0}
.score{color:#f97316;font-weight:bold}
.cat{color:#22c55e;font-weight:bold}
a{color:#93c5fd;text-decoration:none}
.summary{color:#cbd5e1}
.ai-box{background:#0f172a;border-radius:10px;padding:12px;margin-top:12px}
.ai-row{margin:8px 0;line-height:1.6}
.ai-label{display:inline-block;color:#38bdf8;font-weight:bold;width:90px}
.risk-high{color:#ef4444;font-weight:bold}
.risk-mid{color:#f97316;font-weight:bold}
.risk-low{color:#22c55e;font-weight:bold}
</style>
</head>
<body>
<div class="header">
<h1>结构化 AI OSINT 情报分析系统</h1>
<div class="sub">公开信息采集 / 结构化AI研判 / 分类统计 / 风险筛选 / 自动刷新</div>
</div>

<div class="grid">
<div class="card">总数量<div id="total" class="num">0</div></div>
<div class="card">AI/芯片<div id="tech" class="num">0</div></div>
<div class="card">安全情报<div id="sec" class="num">0</div></div>
<div class="card">高风险<div id="high" class="num">0</div></div>
</div>

<div class="charts">
<div class="chart-card"><canvas id="catChart"></canvas></div>
<div class="chart-card"><canvas id="sourceChart"></canvas></div>
<div class="chart-card"><canvas id="riskChart"></canvas></div>
</div>

<div class="toolbar">
<input id="kw" placeholder="搜索标题/摘要/AI研判" oninput="renderList()">
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
        data: { labels: labels, datasets: [{ label: title, data: values }] },
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

function riskClass(risk){
    if(risk === '高') return 'risk-high';
    if(risk === '中') return 'risk-mid';
    return 'risk-low';
}

function renderList(){
    const kw = document.getElementById('kw').value.toLowerCase();
    const risk = document.getElementById('riskFilter').value;

    let data = allData.filter(x => {
        const text = `${x.title} ${x.summary} ${x.ai_summary} ${x.ai_impact} ${x.ai_action}`.toLowerCase();
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
                风险：<span class="${riskClass(x.risk_level)}">${x.risk_level}</span>
            </div>
            <div class="summary">${x.summary || ''}</div>
            <div class="ai-box">
                <div class="ai-row"><span class="ai-label">摘要</span>${x.ai_summary || '暂无'}</div>
                <div class="ai-row"><span class="ai-label">影响</span>${x.ai_impact || '暂无'}</div>
                <div class="ai-row"><span class="ai-label">建议</span>${x.ai_action || '暂无'}</div>
            </div>
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

echo "========== 3. 重建并重启 =========="
cd $BASE
sudo docker compose build --no-cache analyzer api
sudo docker compose up -d analyzer api crawler

echo "========== 4. 重启采集和分析 =========="
sudo docker compose restart crawler analyzer api

echo "========== 5. 当前状态 =========="
sudo docker compose ps

echo "========== 结构化 AI 升级完成 =========="
echo "访问：http://你的Ubuntu_IP:7000"
