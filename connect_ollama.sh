#!/bin/bash
set -e

BASE=~/osint-system

echo "========== 1. 更新 docker-compose.yml =========="

python3 <<'PY'
from pathlib import Path

p = Path.home() / "osint-system" / "docker-compose.yml"
text = p.read_text()

if "OLLAMA_URL:" not in text:
    text = text.replace(
"""      PG_DB: osintdb""",
"""      PG_DB: osintdb
      OLLAMA_URL: http://host.docker.internal:11434/api/generate
      OLLAMA_MODEL: qwen2.5:7b"""
    )

if "extra_hosts:" not in text:
    text = text.replace(
"""    depends_on:
      - redis
      - postgres""",
"""    depends_on:
      - redis
      - postgres
    extra_hosts:
      - "host.docker.internal:host-gateway\""""
    )

p.write_text(text)
PY

echo "========== 2. 更新 analyzer.py =========="

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
    risk_level TEXT
)
""")

cur.execute("ALTER TABLE news ADD COLUMN IF NOT EXISTS ai_summary TEXT")
cur.execute("ALTER TABLE news ADD COLUMN IF NOT EXISTS risk_level TEXT")

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://host.docker.internal:11434/api/generate")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen2.5:7b")

KEYWORDS = {
    "AI": ["AI", "artificial intelligence", "LLM", "OpenAI", "ChatGPT", "model", "GPU", "Claude"],
    "芯片": ["chip", "semiconductor", "NVIDIA", "AMD", "Intel", "ARM", "RISC-V", "GPU"],
    "网络安全": ["security", "hack", "malware", "CVE", "ransomware", "漏洞", "攻击"],
    "国际": ["China", "US", "Russia", "Europe", "war", "trade", "Trump"],
    "技术": ["Linux", "Docker", "Python", "Kubernetes", "open source", "FreeBSD"]
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

def calc_risk(score):
    if score >= 30:
        return "高"
    elif score >= 10:
        return "中"
    return "低"

def ollama_summary(title, summary, category, score):
    prompt = f"""
你是一个中文OSINT公开信息分析助手。请基于以下公开新闻内容，输出简洁中文研判。

标题：{title}
摘要：{summary}
分类：{category}
情报分：{score}

请按以下格式输出：
【一句话摘要】
【可能影响】
【关注等级】低/中/高
【建议动作】
"""

    try:
        resp = requests.post(
            OLLAMA_URL,
            json={
                "model": OLLAMA_MODEL,
                "prompt": prompt,
                "stream": False
            },
            timeout=90
        )
        resp.raise_for_status()
        return resp.json().get("response", "").strip()
    except Exception as e:
        return f"【本地AI调用失败】{e}"

print("analyzer started with Ollama AI", flush=True)

while True:
    data = r.brpop("news", timeout=5)
    if not data:
        continue

    item = json.loads(data[1])

    title = clean_text(item.get("title",""))
    summary = clean_text(item.get("summary",""))
    text = title + " " + summary

    category, score = analyze_category(text)
    risk = calc_risk(score)
    ai_summary = ollama_summary(title, summary, category, score)

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
        risk
    ))

    print("saved with AI:", title, category, score, risk, flush=True)
PY

echo "========== 3. 重建 analyzer =========="
cd $BASE
sudo docker compose build --no-cache analyzer
sudo docker compose up -d analyzer crawler api

echo "========== 4. 完成 =========="
sudo docker compose ps
