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
