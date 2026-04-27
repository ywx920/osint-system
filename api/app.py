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
