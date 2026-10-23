# Cursor Support Pulse

An independent analysis of Cursor's public support forum ([forum.cursor.com](https://forum.cursor.com)). Not affiliated with or endorsed by Cursor.

**The question:** over the last 90 days, which problems cost Cursor's users and support team the most, and does a docs page already answer them?

## Method

1. **Crawl.** Every thread created in the last 90 days in the Bug Reports and Help categories, with all of its posts. Pinned threads and threads opened by staff are left out.
2. **Label.** Claude Haiku reads a sample of thread titles and proposes a short list of issues; a person reviews and edits the list. Haiku then assigns each thread one issue (or Other) and a sentiment from −1 to 1.
3. **Score.** Each issue gets four measures: how many threads it has (frequency), how many people it reaches (distinct users plus likes: breadth), how many staff replies it takes (staff cost), and how negative it reads (negativity). Each is scaled 0 to 1 across issues, and the score is their average. Other is never ranked.
4. **Docs.** For each top-10 issue: do staff link a cursor.com/docs page in at least 20% of its threads? If not, Haiku checks the docs sitemap for a matching page. Each issue ends up *linked*, *unlinked* (a page exists, staff rarely link it) or *missing* (no page).
5. **Launch trend.** Weekly threads (full Mon–Sun weeks) for one launch, Grok Bot (launched Aug 11, 2026: tagged `grok-bot` or named in the title), against everything else, so its share of the forum can be followed week by week.

All of the analysis is SQL (DuckDB, reading the crawled JSON directly) in [`sql/`](sql), run in order by `build.py`.

## Caveats

- **The forum is a slice of Cursor's support, not the queue.** Email and in-app tickets aren't public; forum posters skew toward people comfortable posting in public.
- **The labels come from an LLM.** They are spot-checked by hand (`label.py spot`), not individually verified. Treat issue sizes as estimates.
- **Public data only.** Usernames are used only to count distinct people and are never published. The raw crawl is not redistributed; rerun the crawler to rebuild it.

## Rerun

Python 3 with `duckdb` in `.venv`; labeling calls Claude through the Claude Code CLI (`claude -p`).

```sh
.venv/bin/python crawl.py           # forum -> raw/ (slow and polite: hours)
.venv/bin/python label.py issues    # propose issues -> out/issues_proposed.json
#   review and edit out/issues.json by hand (keep "Other")
.venv/bin/python label.py assign --think  # one issue + sentiment per thread -> out/labels.json
.venv/bin/python build.py           # SQL -> out/top_issues.json + data.js
.venv/bin/python label.py docs      # match top issues to docs pages -> out/doc_matches.json
.venv/bin/python build.py           # again, now with doc status
```

`build.py --raw sample --out-js /tmp/data.js` runs against the small sample in `sample/` (it needs an `out/labels.json` covering those threads).
