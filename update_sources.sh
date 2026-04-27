#!/bin/bash

cat > ~/osint-system/crawler/crawler.py <<'PY'
import feedparser, redis, time, hashlib, json

r = redis.Redis(host="redis", decode_responses=True)

SOURCES = [

    # 国内
    ("IT之家", "https://www.ithome.com/rss/"),
    ("CSDN", "https://www.csdn.net/rss/"),
    ("开源中国", "https://www.oschina.net/news/rss"),
    ("InfoQ中文", "https://www.infoq.cn/feed"),
    ("36氪", "https://36kr.com/feed"),
    ("少数派", "https://sspai.com/feed"),

    # AI
    ("机器之心", "https://www.jiqizhixin.com/rss"),
    ("量子位", "https://www.qbitai.com/feed"),
    ("OpenAI", "https://openai.com/blog/rss.xml"),
    ("HuggingFace", "https://huggingface.co/blog/feed.xml"),

    # 国外社区
    ("Hacker News", "https://hnrss.org/frontpage"),
    ("Reddit Tech", "https://www.reddit.com/r/technology/.rss"),
    ("Reddit AI", "https://www.reddit.com/r/MachineLearning/.rss"),
    ("GitHub Trending", "https://github.com/trending.atom"),

    # 安全
    ("FreeBuf", "https://www.freebuf.com/feed"),
    ("安全客", "https://www.anquanke.com/rss"),

    # 国际
    ("BBC Tech", "http://feeds.bbci.co.uk/news/technology/rss.xml"),
    ("TechCrunch", "https://techcrunch.com/feed/"),
]

def fetch():
    for name, url in SOURCES:
        try:
            d = feedparser.parse(url)
            for e in d.entries[:10]:
                title = e.get("title", "")
                link = e.get("link", "")
                summary = e.get("summary", "")

                uid = hashlib.md5((title+link).encode()).hexdigest()

                data = {
                    "id": uid,
                    "source": name,
                    "title": title,
                    "summary": summary,
                    "link": link,
                    "ts": int(time.time())
                }

                r.lpush("news", json.dumps(data))

            print(f"OK {name}")

        except Exception as ex:
            print(f"ERR {name} {ex}")

while True:
    fetch()
    time.sleep(60)
PY

echo "更新完成"
