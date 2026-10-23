-- 05_launches.sql
-- What a launch does to the forum: tags that first appear partway through
-- the window, and their weekly thread counts from that first thread on.
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
