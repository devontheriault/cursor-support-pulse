-- 05_launches.sql
-- What a launch does to the forum, two ways:
--   launches   every tag that first appears partway through the window, with
--              its weekly thread counts from that first thread on (LAUNCHES)
--   trend      one launch, Grok Bot, against everything else, week by week
--              across the whole window (TREND, card 3)
--
-- Both read `threads` (01_threads.sql), so they share its scope: Bug Reports
-- and Help, created in the window, not pinned, opened by a user.


-- Part 1: launches ----------------------------------------------------------
--
-- A tag counts as new if its first thread is >= 7 days after the window
-- opens; older tags may simply predate the crawl. Week 0 is the 7 days from
-- the first tagged thread. Weeks 0-4 are shown, cut where the window ends:
-- a week is kept only once it is complete, so a partial final week never
-- reads as a drop-off. Week 0 is always kept, even for a tag days old.
-- Top 4 by week-0 threads (ties: more threads overall).


CREATE OR REPLACE TABLE launches AS
WITH

thread_tags AS (
    SELECT id, created_at, unnest(tags) AS tag
    FROM threads
),

new_tags AS (
    SELECT tag, min(created_at) AS first_seen
    FROM thread_tags
    GROUP BY tag
    HAVING min(created_at) >= getvariable('window_from') + INTERVAL 7 DAY
),

weeks AS (
    SELECT
        n.tag,
        n.first_seen,
        w.week,
        n.first_seen + to_days(CAST(7 * w.week AS INTEGER))       AS week_start,
        n.first_seen + to_days(CAST(7 * (w.week + 1) AS INTEGER)) AS week_end
    FROM new_tags AS n,
         range(5) AS w(week)
),

complete_weeks AS (
    SELECT *
    FROM weeks
    WHERE week = 0 OR week_end <= getvariable('window_to')
),

weekly AS (
    SELECT
        w.tag,
        w.first_seen,
        w.week,
        count(t.id) AS threads
    FROM complete_weeks AS w
    LEFT JOIN thread_tags AS t
        ON t.tag = w.tag
       AND t.created_at >= w.week_start
       AND t.created_at <  w.week_end
    GROUP BY w.tag, w.first_seen, w.week
)

SELECT
    tag,
    -- "grok-bot" -> "Grok Bot"; common acronyms stay upper case ("mcp-server" -> "MCP Server").
    array_to_string(
        [CASE
            WHEN word IN ('ai', 'api', 'cli', 'gpt', 'ide', 'llm', 'mcp', 'ms', 'pr', 'sso', 'ssh', 'ui', 'wsl', 'byok', 'json', 'url')
                THEN upper(word)
            ELSE upper(word[1]) || word[2:]
         END
         FOR word IN string_split(replace(tag, '_', '-'), '-')
         IF word <> ''],
        ' '
    )                                       AS label,
    first_seen::DATE                        AS first_seen,
    list(threads ORDER BY week)             AS weeks
FROM weekly
GROUP BY tag, first_seen
ORDER BY weeks[1] DESC, list_sum(weeks) DESC, tag
LIMIT 4;


-- Part 2: trend -------------------------------------------------------------
--
-- The launch being tracked, and where its date comes from. Grok Bot (xAI's
-- AI-teammate app, sold with Cursor plans) launched in early beta on
-- Aug 11, 2026: Cursor's forum announcement went up at 19:34 UTC, and the
-- first thread tagged grok-bot was opened four minutes earlier. Cursor's
-- changelog has no entry for it. No thread from before Aug 11 is about
-- Grok Bot, so there was no visible pre-launch beta.
CREATE OR REPLACE TABLE trend_launch AS
SELECT
    'grok-bot'                              AS key,
    'Grok Bot'                              AS label,
    DATE '2026-08-11'                       AS date,
    'Cursor forum announcement'             AS source,
    'https://forum.cursor.com/t/168053'     AS url;


-- What counts as a Grok Bot thread: tagged grok-bot (forum staff tag
-- threads as they triage them), or untagged but naming Grok Bot in the
-- title ("Grokbot", "Grok bot"). Not the `grok` tag: that one is for the
-- Grok models (Grok 4.5, 4.6, 4.7) inside Cursor's own agent, a different
-- product with its own launches.
CREATE OR REPLACE TABLE trend_threads AS
SELECT
    id,
    created_at,
    list_contains(tags, 'grok-bot')
        OR regexp_matches(title, '(?i)\bgrok ?bot\b')  AS is_launch
FROM threads;


-- Full Mon-Sun weeks only (ISO weeks, UTC), each named by its Monday: the
-- first Monday on or after the window opens, up to the last Sunday before
-- it closes. The partial weeks at either end would read as dips.
CREATE OR REPLACE TABLE trend AS
WITH

bounds AS (
    SELECT
        CASE WHEN getvariable('window_from') = date_trunc('week', getvariable('window_from'))
             THEN getvariable('window_from')
             ELSE date_trunc('week', getvariable('window_from')) + INTERVAL 7 DAY
        END                                         AS first_monday,
        getvariable('window_to')                    AS window_to
),

weeks AS (
    SELECT w.week_start
    FROM bounds AS b,
         range(b.first_monday, b.window_to, INTERVAL 7 DAY) AS w(week_start)
    WHERE w.week_start + INTERVAL 7 DAY <= b.window_to
)

SELECT
    w.week_start::DATE                              AS week,
    count(t.id) FILTER (WHERE t.is_launch)          AS launch,
    count(t.id) FILTER (WHERE NOT t.is_launch)      AS rest
FROM weeks AS w
LEFT JOIN trend_threads AS t
    ON t.created_at >= w.week_start
   AND t.created_at <  w.week_start + INTERVAL 7 DAY
GROUP BY w.week_start
ORDER BY w.week_start;
