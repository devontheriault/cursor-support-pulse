"""Fetch Cursor's status-page incident history into raw/status/, per CONTRACT.md.

Usage: .venv/bin/python status.py

  raw/status/history_p{N}.json        https://status.cursor.com/history.json?page=N, exactly as
                                      returned (3 months a page, newest first). Paging stops once a
                                      page's oldest month starts before the crawl window opens.
  raw/status/incidents/{code}.json    https://status.cursor.com/incidents/{code}.json for every
                                      incident in a month that overlaps the window: exact started_at / created_at /
                                      resolved_at, which the history page only gives as a
                                      "Oct 21, 17:40 - 17:53 UTC" string with no year.
  raw/status/status.json              {started_at, finished_at, pages, incidents, errors}

Same manners as crawl.py (it reuses its fetcher): one request at a time, >= 2 s apart, a named
User-Agent, backoff on 429/5xx. Files already in raw/status/ are skipped, so a rerun only fetches
new incidents. The window comes from raw/crawl.json, so run crawl.py first.
"""

import json
import sys
from datetime import datetime, timezone

from crawl import RAW, STATE, Crawler, iso, log, parse_ts, write_atomic

STATUS_SITE = "https://status.cursor.com"
STATUS = RAW / "status"
INCIDENTS = STATUS / "incidents"
STATUS_STATE = STATUS / "status.json"
MAX_PAGES = 12        # 3 years of history: a safety stop, never reached for a 90-day window
MONTHS = {m: i for i, m in enumerate(
    ["January", "February", "March", "April", "May", "June", "July",
     "August", "September", "October", "November", "December"], 1)}


class StatusCrawler(Crawler):
    """crawl.py's fetcher, keeping its own state file instead of raw/crawl.json."""

    def save_state(self):
        self.state["pages"] = len(list(STATUS.glob("history_p*.json")))
        self.state["incidents"] = len(list(INCIDENTS.glob("*.json")))
        write_atomic(STATUS_STATE, (json.dumps(self.state, indent=2) + "\n").encode())


def fetch(c, path, url, label):
    """Cached body for path, fetching url once if it isn't on disk yet."""
    if path.exists():
        return path.read_bytes()
    body = c.get(url, label)
    if body is not None:
        write_atomic(path, body)
        c.save_state()
    return body


def main():
    if not STATE.exists():
        sys.exit(f"{STATE} not found: run crawl.py first (the status window follows the forum's).")
    window_from = parse_ts(json.loads(STATE.read_text())["window_from"])
    c = StatusCrawler({"started_at": iso(datetime.now(timezone.utc)), "finished_at": None,
                       "pages": 0, "incidents": 0, "errors": []})

    codes = []
    for page in range(1, MAX_PAGES + 1):
        body = fetch(c, STATUS / f"history_p{page}.json",
                     f"{STATUS_SITE}/history.json?page={page}", f"history p{page}")
        if body is None:
            log(f"history p{page} failed; stopping")
            break
        months = json.loads(body).get("months", [])
        # Only months that overlap the window: older incidents can't matter.
        codes += [i["code"] for m in months
                  if (m["year"], MONTHS[m["name"]]) >= (window_from.year, window_from.month)
                  for i in m.get("incidents", [])]
        oldest = min((datetime(m["year"], MONTHS[m["name"]], 1, tzinfo=timezone.utc) for m in months),
                     default=None)
        if oldest is None or oldest <= window_from:
            break

    log(f"{len(codes)} incidents on {page} history pages")
    for n, code in enumerate(codes, 1):
        fetch(c, INCIDENTS / f"{code}.json", f"{STATUS_SITE}/incidents/{code}.json", f"[{n}/{len(codes)}]")

    c.state["finished_at"] = iso(datetime.now(timezone.utc))
    c.save_state()
    log(f"done: {c.state['pages']} pages, {c.state['incidents']} incidents, "
        f"{len(c.state['errors'])} errors, {c.requests} requests")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
