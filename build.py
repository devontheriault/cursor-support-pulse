"""Build the analysis: raw/ + out/labels.json -> out/top_issues.json + data.js.

Runs sql/01..05 in DuckDB over the crawled JSON, then writes:
  out/top_issues.json  the top 10 with sample titles (input to label.py docs)
  data.js              the ES module the page imports (shape in CONTRACT.md)

    .venv/bin/python build.py                       # raw/ -> the website
    .venv/bin/python build.py --raw sample --out-js /tmp/data.js

Safe to run before out/doc_matches.json exists: doc status is then 'unknown'.
"""

import argparse
import json
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent
SQL_STEPS = ["01_threads", "02_issues", "03_scores", "04_docs", "05_launches"]
WINDOW_DAYS = 90
FORUM = "https://forum.cursor.com/t/"
REPO = "https://github.com/devontheriault/cursor-support-pulse"
DEFAULT_JS = Path.home() / "Projects" / "Personal Website" / "cursor" / "data.js"


def main() -> None:
    args = parse_args()
    raw, out = args.raw.resolve(), args.out.resolve()

    topics_glob = find_topics(raw)
    labels_path = out / "labels.json"
    if not labels_path.exists():
        sys.exit(f"{labels_path} not found: run label.py assign first.")
    doc_matches_path = out / "doc_matches.json"
    doc_matches = doc_matches_path.read_text() if doc_matches_path.exists() else "{}"

    crawl = read_crawl(raw)
    window_from, window_to, meta_from, meta_to = resolve_window(crawl)
    as_of = (crawl.get("finished_at") or "")[:10] or date.today().isoformat()

    con = duckdb.connect()
    con.execute("SET TimeZone = 'UTC'")
    for name, value in {
        "topics_glob": topics_glob,
        "labels_path": str(labels_path),
        "window_from": window_from,
        "window_to": window_to,
        "doc_matches": doc_matches,
    }.items():
        con.execute(f"SET VARIABLE {name} = ?", [value])

    for step in SQL_STEPS:
        con.execute((ROOT / "sql" / f"{step}.sql").read_text())

    issues = top_issues(con)
    launches = rows(con, "SELECT tag, label, first_seen::VARCHAR AS first_seen, weeks FROM launches")
    totals = rows(con, """
        SELECT
            count(*)                                   AS threads,
            (SELECT count(DISTINCT user_id)
               FROM threads, unnest(user_ids) AS u(user_id)) AS users,
            count(*) FILTER (WHERE NOT is_labeled)     AS unlabeled
        FROM threads
    """)[0]

    top10_threads = sum(i["threads"] for i in issues)
    meta = {
        "asOf": as_of,
        "windowDays": round((window_to - window_from) / timedelta(days=1)),
        "from": meta_from,
        "to": meta_to,
        "categories": ["Bug Reports", "Help"],
        "repo": REPO,
    }
    header = {
        "threads": totals["threads"],
        "users": totals["users"],
        "top10Threads": top10_threads,
        "top10Share": r2(top10_threads / totals["threads"]) if totals["threads"] else 0,
        "top10Missing": sum(i["doc_status"] == "missing" for i in issues),
    }

    out.mkdir(parents=True, exist_ok=True)
    (out / "top_issues.json").write_text(json.dumps(
        [{"rank": i["rank"], "issue": i["issue"], "threads": i["threads"],
          "sample_titles": i["sample_titles"]} for i in issues],
        indent=2, ensure_ascii=False,
    ) + "\n")

    args.out_js.parent.mkdir(parents=True, exist_ok=True)
    args.out_js.write_text(render_js(meta, header, issues, launches))

    print_summary(con, meta, header, totals, issues, launches, doc_matches_path, args.out_js)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--raw", type=Path, default=ROOT / "raw",
                   help="crawl directory: raw (default) or sample")
    p.add_argument("--out", type=Path, default=ROOT / "out",
                   help="reads labels.json and doc_matches.json, writes top_issues.json")
    p.add_argument("--out-js", type=Path, default=DEFAULT_JS,
                   help=f"where to write data.js (default {DEFAULT_JS})")
    return p.parse_args()


def find_topics(raw: Path) -> str:
    """raw/ keeps topics in topics/{id}.json; sample/ names them topic_{id}.json."""
    for pattern in ("topics/*.json", "topic_*.json"):
        if any(raw.glob(pattern)):
            return str(raw / pattern)
    sys.exit(f"No topic files in {raw}: run crawl.py first.")


def read_crawl(raw: Path) -> dict:
    path = raw / "crawl.json"
    return json.loads(path.read_text()) if path.exists() else {}


def resolve_window(crawl: dict) -> tuple[datetime, datetime, str, str]:
    """The window as UTC timestamps [from, to) plus the dates shown on the page.

    Taken from raw/crawl.json; a date-only bound covers that whole day. Without
    a crawl.json (sample/), the window is the 90 days up to now.
    """
    def parse(value: str, end: bool) -> datetime:
        if len(value) == 10:  # 'YYYY-MM-DD'
            day = datetime.fromisoformat(value)
            return day + timedelta(days=1) if end else day
        ts = datetime.fromisoformat(value)
        return ts.astimezone(timezone.utc).replace(tzinfo=None) if ts.tzinfo else ts

    if crawl.get("window_from") and crawl.get("window_to"):
        window_from = parse(crawl["window_from"], end=False)
        window_to = parse(crawl["window_to"], end=True)
        return window_from, window_to, crawl["window_from"][:10], crawl["window_to"][:10]

    if crawl.get("started_at"):
        window_to = parse(crawl["started_at"], end=False)
    else:
        window_to = datetime.now(timezone.utc).replace(tzinfo=None)
    window_from = window_to - timedelta(days=WINDOW_DAYS)
    return window_from, window_to, window_from.date().isoformat(), window_to.date().isoformat()


def top_issues(con: duckdb.DuckDBPyConnection) -> list[dict]:
    return rows(con, """
        SELECT
            s.rank, s.issue, i.threads, i.users, i.likes, i.staff_posts, i.sentiment,
            s.frequency, s.breadth, s.staff_cost, s.negativity, s.score,
            d.status AS doc_status, d.url AS doc_url, d.linked_share,
            i.example_id, i.sample_titles
        FROM scores AS s
        JOIN issues   AS i USING (issue)
        JOIN top_docs AS d USING (issue)
        ORDER BY s.rank
    """)


def rows(con: duckdb.DuckDBPyConnection, sql: str) -> list[dict]:
    cur = con.execute(sql)
    names = [c[0] for c in cur.description]
    return [dict(zip(names, row)) for row in cur.fetchall()]


def r2(x: float | None) -> float | None:
    return None if x is None else round(x, 2)


# --- data.js ---------------------------------------------------------------

def render_js(meta: dict, header: dict, issues: list[dict], launches: list[dict]) -> str:
    issue_objs = [{
        "rank": i["rank"],
        "issue": i["issue"],
        "threads": i["threads"],
        "users": i["users"],
        "likes": i["likes"],
        "staffPosts": i["staff_posts"],
        "sentiment": r2(i["sentiment"] or 0),
        "parts": {
            "frequency": r2(i["frequency"]),
            "breadth": r2(i["breadth"]),
            "staffCost": r2(i["staff_cost"]),
            "negativity": r2(i["negativity"]),
        },
        "score": r2(i["score"]),
        "doc": {"status": i["doc_status"], "url": i["doc_url"], "linkedShare": r2(i["linked_share"])},
        "example": f"{FORUM}{i['example_id']}",
    } for i in issues]
    launch_objs = [{
        "tag": l["tag"], "label": l["label"], "firstSeen": l["first_seen"], "weeks": l["weeks"],
    } for l in launches]

    lines = [
        "// Generated by cursor-support-pulse/build.py. Do not edit.",
        f"export const META = {js(meta)};",
        f"export const HEADER = {js(header)};",
        "// Top 10 by score, rank 1 first. parts are each 0–1 (min-max over all issues except Other); score = their mean.",
        "export const ISSUES = [",
        *(f"  {js(o)}," for o in issue_objs),
        "];",
        "// doc.status: 'linked' (staff link a /docs or /help page in ≥ 20% of the issue's threads; url = most-linked page),",
        "// 'unlinked' (a matching doc exists but staff rarely link it), 'missing' (no matching doc), 'unknown' (not matched yet).",
        "// Launches: tags first seen ≥ 7 days after the window opens, top 4 by week-0 threads. week 0 = the 7 days from the first tagged thread.",
        "export const LAUNCHES = [",
        *(f"  {js(o)}," for o in launch_objs),
        "];",
    ]
    return "\n".join(lines) + "\n"


def js(value) -> str:
    """A JS literal in the contract's style: bare keys, single-quoted strings."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        # JSON's escaping is valid JS; swap the quote style.
        body = json.dumps(value, ensure_ascii=False)[1:-1]
        return "'" + body.replace('\\"', '"').replace("'", "\\'") + "'"
    if isinstance(value, (list, tuple)):
        return "[" + ", ".join(js(v) for v in value) + "]"
    if isinstance(value, dict):
        return "{ " + ", ".join(f"{k}: {js(v)}" for k, v in value.items()) + " }"
    raise TypeError(f"can't render {type(value).__name__} as JS")


# --- stdout ----------------------------------------------------------------

def print_summary(con, meta, header, totals, issues, launches, doc_matches_path, out_js) -> None:
    funnel = rows(con, """
        SELECT
            count(*)                                                    AS topic_files,
            count(*) FILTER (WHERE in_category)                         AS in_categories,
            count(*) FILTER (WHERE in_category AND in_window)           AS in_window,
            count(*) FILTER (WHERE in_category AND in_window
                               AND NOT is_pinned)                       AS not_pinned,
            count(*) FILTER (WHERE in_category AND in_window
                               AND NOT is_pinned AND NOT staff_opened)  AS user_opened
        FROM scope
    """)[0]
    print(f"Cursor Support Pulse: {meta['from']} to {meta['to']} ({meta['windowDays']} days), as of {meta['asOf']}")
    print("Scope: " + " -> ".join(f"{v} {k.replace('_', ' ')}" for k, v in funnel.items()))
    labeled = totals["threads"] - totals["unlabeled"]
    print(f"Labels: {labeled} of {totals['threads']} threads labeled"
          + (f"; {totals['unlabeled']} unlabeled, counted as Other" if totals["unlabeled"] else ""))
    print(f"Header: {header['threads']} threads, {header['users']} users; top 10 = "
          f"{header['top10Threads']} threads ({header['top10Share']:.0%}), {header['top10Missing']} with no doc")
    print()

    cols = [("#", 2), ("issue", 34), ("threads", 7), ("users", 6), ("likes", 6), ("staff", 6),
            ("sent", 6), ("freq", 5), ("brdth", 5), ("cost", 5), ("neg", 5), ("score", 5),
            ("doc", 8), ("linked", 6)]
    print("  ".join(f"{name:<{w}}" if i < 2 else f"{name:>{w}}" for i, (name, w) in enumerate(cols)))
    for i in issues:
        cells = [i["rank"], i["issue"][:34], i["threads"], i["users"], i["likes"], i["staff_posts"],
                 f"{i['sentiment'] or 0:+.2f}", f"{i['frequency']:.2f}", f"{i['breadth']:.2f}",
                 f"{i['staff_cost']:.2f}", f"{i['negativity']:.2f}", f"{i['score']:.2f}",
                 i["doc_status"], f"{i['linked_share']:.0%}"]
        print("  ".join(f"{c:<{w}}" if n < 2 else f"{c:>{w}}" for n, (c, (_, w)) in enumerate(zip(cells, cols))))
    for i in issues:
        if i["doc_url"]:
            print(f"   {i['rank']:>2}. {i['doc_status']}: {i['doc_url']}")

    print("\nLaunches (threads per week from first seen):")
    for l in launches or [{"label": "(none)", "tag": "", "first_seen": "", "weeks": []}]:
        print(f"  {l['label']:<24} {l['tag']:<20} {l['first_seen']:<10}  {l['weeks']}")

    unknown = sum(i["doc_status"] == "unknown" for i in issues)
    if unknown:
        hint = "rerun label.py docs (top 10 changed)" if doc_matches_path.exists() else "run label.py docs, then build.py"
        print(f"\n{unknown} top issues have doc status 'unknown': {hint}.")
    print(f"\nWrote {doc_matches_path.parent / 'top_issues.json'} and {out_js}")


if __name__ == "__main__":
    main()
