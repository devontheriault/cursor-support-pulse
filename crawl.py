"""Crawl forum.cursor.com (Bug Reports + Help) into raw/, per CONTRACT.md.

Usage: .venv/bin/python crawl.py [--days 90] [--limit N]

Polite by design: one request at a time, >= 2 s between requests, exponential
backoff on 429/5xx (honouring Retry-After), 5 tries per URL. Resumable: files
already in raw/ are skipped, and an existing raw/crawl.json with the same
--days keeps its started_at, so the window is identical across restarts.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

FORUM = "https://forum.cursor.com"
SITEMAP = "https://cursor.com/docs/sitemap.xml"
CATEGORIES = (6, 8)
UA = "cursor-support-pulse/0.1 (independent research; devontheriault@live.ca)"
MIN_GAP = 2.0          # seconds between the end of one request and the start of the next
TRIES = 5
CHUNK = 20             # post ids per /t/{id}/posts.json request
MAX_WAIT = 600         # cap on a single backoff sleep

ROOT = Path(__file__).resolve().parent
RAW = ROOT / "raw"
LISTS = RAW / "lists"
TOPICS = RAW / "topics"
STATE = RAW / "crawl.json"


def log(msg):
    print(f"{datetime.now().strftime('%H:%M:%S')} {msg}", flush=True)


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


class Crawler:
    def __init__(self, state):
        self.state = state
        self.last = 0.0
        self.requests = 0

    def save_state(self):
        self.state["lists"] = len(list(LISTS.glob("*.json")))
        self.state["topics"] = len(list(TOPICS.glob("*.json")))
        write_atomic(STATE, (json.dumps(self.state, indent=2) + "\n").encode())

    def error(self, url, status, msg):
        self.state["errors"].append({"url": url, "status": status, "error": msg, "at": iso(datetime.now(timezone.utc))})
        self.save_state()

    def get(self, url, label=""):
        """Return the response body, or None after logging a permanent failure."""
        for attempt in range(1, TRIES + 1):
            wait = self.last + MIN_GAP - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            t0 = time.monotonic()
            status, retry_after, body, err = None, None, None, None
            try:
                req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json, */*"})
                with urllib.request.urlopen(req, timeout=60) as r:
                    status, body = r.status, r.read()
            except urllib.error.HTTPError as e:
                status, retry_after, err = e.code, e.headers.get("Retry-After"), f"HTTP {e.code}"
            except Exception as e:  # network error, timeout, reset
                err = f"{type(e).__name__}: {e}"
            self.last = time.monotonic()
            self.requests += 1
            ms = int((self.last - t0) * 1000)
            log(f"{status or 'ERR'} {ms}ms {label} {url}" + (f" ({err})" if err else ""))
            if body is not None:
                return body
            retryable = status is None or status == 429 or status >= 500
            if not retryable:
                self.error(url, status, err)
                return None
            if attempt == TRIES:
                break
            delay = 5 * 2 ** (attempt - 1)  # 5, 10, 20, 40
            if retry_after:
                try:
                    delay = max(delay, float(retry_after))
                except ValueError:
                    pass
            delay = min(delay, MAX_WAIT)
            log(f"  backoff {delay:.0f}s (try {attempt}/{TRIES})")
            time.sleep(delay)
        self.error(url, status, f"gave up after {TRIES} tries: {err}")
        return None


def crawl_lists(c, cat, window_from):
    """Fetch list pages newest-created first; return in-window topic ids."""
    ids = []
    page = 0
    while True:
        path = LISTS / f"{cat}_p{page}.json"
        url = f"{FORUM}/c/{cat}/l/latest.json?order=created&ascending=false&page={page}"
        if path.exists():
            body = path.read_bytes()
            log(f"skip {path.relative_to(ROOT)}")
        else:
            body = c.get(url, f"list {cat} p{page}")
            if body is None:
                log(f"list {cat} p{page} failed; stopping this category")
                break
            write_atomic(path, body)
            c.save_state()
        tl = json.loads(body)["topic_list"]
        topics = tl.get("topics", [])
        for t in topics:
            if parse_ts(t["created_at"]) >= window_from and t["id"] not in ids:
                ids.append(t["id"])
        unpinned = [t for t in topics if not t.get("pinned")]
        oldest = min((parse_ts(t["created_at"]) for t in unpinned), default=None)
        if not topics or not tl.get("more_topics_url") or oldest is None or oldest < window_from:
            break
        page += 1
    log(f"category {cat}: {page + 1} pages, {len(ids)} in-window topics")
    return ids


def crawl_topic(c, tid, label):
    path = TOPICS / f"{tid}.json"
    if path.exists():
        return
    body = c.get(f"{FORUM}/t/{tid}.json", label)
    if body is None:
        return
    topic = json.loads(body)
    ps = topic["post_stream"]
    have = {p["id"] for p in ps["posts"]}
    missing = [pid for pid in ps.get("stream", []) if pid not in have]
    posts = list(ps["posts"])
    for i in range(0, len(missing), CHUNK):
        chunk = missing[i:i + CHUNK]
        q = "&".join(f"post_ids[]={pid}" for pid in chunk)
        more = c.get(f"{FORUM}/t/{tid}/posts.json?{q}", f"{label} posts {i // CHUNK + 1}")
        if more is None:
            log(f"  topic {tid} incomplete; not saved (will retry on resume)")
            return
        for p in json.loads(more)["post_stream"]["posts"]:
            if p["id"] not in have:
                have.add(p["id"])
                posts.append(p)
    ps["posts"] = sorted(posts, key=lambda p: p["post_number"])
    write_atomic(path, json.dumps(topic, ensure_ascii=False).encode())
    c.save_state()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=90)
    ap.add_argument("--limit", type=int, default=None, help="stop after N topics (testing)")
    args = ap.parse_args()

    now = datetime.now(timezone.utc)
    started = now
    if STATE.exists():
        old = json.loads(STATE.read_text())
        span = parse_ts(old["window_to"]) - parse_ts(old["window_from"])
        if span == timedelta(days=args.days):
            started = parse_ts(old["started_at"])
            log(f"resuming crawl started {old['started_at']}")
        else:
            log(f"existing crawl.json has a {span} window, not {args.days} days: starting a new window")
    window_to = started
    window_from = started - timedelta(days=args.days)
    state = {
        "started_at": iso(started),
        "finished_at": None,
        "window_from": iso(window_from),
        "window_to": iso(window_to),
        "lists": 0,
        "topics": 0,
        "errors": [],
    }
    c = Crawler(state)
    c.save_state()
    log(f"window {state['window_from']} .. {state['window_to']}")

    ids = []
    for cat in CATEGORIES:
        ids += [i for i in crawl_lists(c, cat, window_from) if i not in ids]
    if args.limit is not None:
        ids = ids[:args.limit]
    todo = [i for i in ids if not (TOPICS / f"{i}.json").exists()]
    log(f"{len(ids)} in-window topics, {len(todo)} to fetch")

    if not (RAW / "docs_sitemap.xml").exists():
        body = c.get(SITEMAP, "sitemap")
        if body is not None:
            write_atomic(RAW / "docs_sitemap.xml", body)

    t0 = time.monotonic()
    for n, tid in enumerate(todo, 1):
        crawl_topic(c, tid, f"[{n}/{len(todo)}]")
        if n % 50 == 0:
            rate = (time.monotonic() - t0) / n
            log(f"progress {n}/{len(todo)} topics, ~{(len(todo) - n) * rate / 60:.0f} min left")

    state["finished_at"] = iso(datetime.now(timezone.utc))
    c.save_state()
    log(f"done: {state['lists']} lists, {state['topics']} topics, {len(state['errors'])} errors, {c.requests} requests")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
