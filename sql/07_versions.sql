-- 07_versions.sql
-- Which app updates broke things? (VERSIONS, card 4)
--
-- Reads `threads` (01_threads.sql, same scope), whose app_version is the
-- Cursor version the reporter names in the bug template ("Version: 3.21.4"
-- -> '3.21'; see 01 for what counts). Patch releases (3.21.4, 3.21.5) are
-- folded into their minor version: they ship days apart and people rarely
-- update between them, so the minor version is the update people notice.
--
-- Rules:
--   * firstSeen: the earliest thread naming the version. Beta and early-
--     access users name it a few days before the public release, so this
--     runs slightly early; there is no release date in the data to use instead.
--   * week1: threads naming it in the 7 days from firstSeen. total: every
--     thread in the window naming it.
--   * Kept: first seen >= 7 days after the window opens (a version already
--     out when the window opened would have its week 1 cut off or missing),
--     week 1 complete inside the window, and >= 15 threads in total.
--   * topIssue: the most common issue (not Other) among its week-1 threads;
--     ties go to the issue with more threads overall, then by name.
--   * worst: the highest week1. median: the median week1 of the kept
--     versions other than the worst, the "typical update" it is compared to.


CREATE OR REPLACE TABLE versions AS
WITH

named AS (
    SELECT id, created_at, issue, app_version AS version
    FROM threads
    WHERE app_version IS NOT NULL
),

firsts AS (
    SELECT version, min(created_at) AS first_seen, count(*) AS total
    FROM named
    GROUP BY version
),

kept AS (
    SELECT *
    FROM firsts
    WHERE first_seen >= getvariable('window_from') + INTERVAL 7 DAY
      AND first_seen + INTERVAL 7 DAY <= getvariable('window_to')
      AND total >= 15
),

week1 AS (
    SELECT k.version, n.id, n.issue
    FROM kept AS k
    JOIN named AS n
        ON n.version = k.version
       AND n.created_at >= k.first_seen
       AND n.created_at <  k.first_seen + INTERVAL 7 DAY
),

week1_issues AS (
    SELECT
        w.version,
        w.issue,
        count(*)                                                AS threads,
        row_number() OVER (PARTITION BY w.version
                           ORDER BY count(*) DESC, any_value(i.threads) DESC, w.issue) AS pick
    FROM week1 AS w
    LEFT JOIN issues AS i USING (issue)
    WHERE w.issue <> 'Other'
    GROUP BY w.version, w.issue
)

SELECT
    k.version,
    k.first_seen,
    (SELECT count(*) FROM week1 AS w WHERE w.version = k.version)  AS week1,
    k.total,
    t.issue                                                     AS top_issue,
    t.threads                                                   AS top_issue_week1
FROM kept AS k
LEFT JOIN week1_issues AS t
    ON t.version = k.version
   AND t.pick = 1
ORDER BY k.first_seen;


CREATE OR REPLACE TABLE version_summary AS
WITH

worst AS (
    SELECT version
    FROM versions
    ORDER BY week1 DESC, first_seen
    LIMIT 1
)

SELECT
    (SELECT count(*) FROM threads)                              AS threads,
    (SELECT count(app_version) FROM threads)                    AS covered,
    (SELECT median(week1) FROM versions
      WHERE version NOT IN (SELECT version FROM worst))         AS median,
    (SELECT version FROM worst)                                 AS worst;
