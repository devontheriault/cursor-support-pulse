-- 06_incidents.sql
-- Do outages on Cursor's status page (status.cursor.com) bring people to the
-- forum? (INCIDENTS)
--
-- Reads `threads` (01_threads.sql, same scope: Bug Reports and Help, created
-- in the window, not pinned, opened by a user), `scores` (03) for the top 10,
-- and `status_incidents`, which build.py loads from raw/status/ (status.py):
--   code, name, impact ('none' | 'minor' | 'major' | 'critical'),
--   started_at, resolved_at (TIMESTAMP, UTC)
-- started_at is the incident's created_at from /incidents/{code}.json:
-- staff backdate it to when the trouble began (Oct 21, 10:21 posted as
-- started 10:37), and it is the time the history page shows.
--
-- Rules:
--   * An incident counts if it started inside the window with its whole
--     6-hour "during" window inside it too, so every incident gets the same
--     6 hours. Scheduled maintenance is not an outage and is left out.
--   * A thread is "during" an incident if it opened in the 6 h after any
--     incident started. Incidents overlap (one outage often gets two or three
--     entries), so the windows are merged first: a thread counts once.
--   * Baseline: what a normal week has in those same hours. Each moment of
--     the merged windows is compared with the same moment 7 and 14 days
--     earlier (same weekday, same hour: the forum is busier on weekdays and
--     in US daytime), averaging the shifts that land inside the window; moments in the
--     window's first week have neither shift and are left out of both
--     sides. Done
--     per thread: a thread opened at t stands in for t + 7 days and t + 14
--     days, weighted 1 / (shifts available at that moment).
--   * The highlighted issue: the top-10 issue whose threads rise most during
--     incidents (highest during / baseline), among issues with at least 15
--     during threads, so a 3-vs-1 blip can't win.


SET VARIABLE incident_hours = 6;


CREATE OR REPLACE TABLE incidents AS
SELECT code, name, impact, started_at, resolved_at
FROM status_incidents
WHERE NOT is_maintenance
  AND started_at >= getvariable('window_from')
  AND started_at + to_hours(getvariable('incident_hours')) <= getvariable('window_to');


-- The 6-hour windows, overlapping ones merged (gaps-and-islands: a window
-- starts a new island when it opens after every earlier window has closed).
CREATE OR REPLACE TABLE incident_windows AS
WITH

windows AS (
    SELECT
        started_at                                              AS w_start,
        started_at + to_hours(getvariable('incident_hours'))    AS w_end
    FROM incidents
),

flagged AS (
    SELECT
        w_start,
        w_end,
        coalesce(
            w_start > max(w_end) OVER (ORDER BY w_start, w_end
                                       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
            true)                                               AS new_island
    FROM windows
),

islands AS (
    SELECT w_start, w_end, sum(new_island::INTEGER) OVER (ORDER BY w_start, w_end) AS island
    FROM flagged
)

SELECT min(w_start) AS w_start, max(w_end) AS w_end
FROM islands
GROUP BY island;


-- Every in-scope thread, once as itself (shift 0: is it during an incident?)
-- and once per baseline shift (does t + 7 or 14 days fall in one?).
CREATE OR REPLACE TABLE incident_threads AS
WITH

shifted AS (
    SELECT t.id, t.issue, s.shift_days, t.created_at + to_days(s.shift_days) AS shifted_at
    FROM threads AS t,
         (VALUES (0), (7), (14)) AS s(shift_days)
    -- A moment in the window's first 7 days has no earlier week to compare
    -- with, so it counts on neither side (the incident still counts).
    WHERE t.created_at + to_days(s.shift_days) >= getvariable('window_from') + INTERVAL 7 DAY
),

hits AS (
    SELECT DISTINCT s.id, s.issue, s.shift_days, s.shifted_at
    FROM shifted AS s
    JOIN incident_windows AS w
        ON s.shifted_at >= w.w_start
       AND s.shifted_at <  w.w_end
)

SELECT
    id,
    issue,
    shift_days = 0                                              AS is_during,
    CASE
        WHEN shift_days = 0 THEN 0
        -- The 7-day shift always lands in the window when this thread does;
        -- the 14-day shift only if the moment is 14+ days into the window.
        ELSE 1.0 / (1 + (shifted_at - INTERVAL 14 DAY >= getvariable('window_from'))::INTEGER)
    END                                                         AS baseline_weight
FROM hits;


CREATE OR REPLACE TABLE incident_effect AS
WITH

by_issue AS (
    SELECT
        issue,
        count(*) FILTER (WHERE is_during)                       AS during,
        sum(baseline_weight)                                    AS baseline
    FROM incident_threads
    GROUP BY issue
),

top10 AS (
    SELECT s.rank, s.issue, s.threads, coalesce(b.during, 0) AS during, coalesce(b.baseline, 0) AS baseline
    FROM scores AS s
    LEFT JOIN by_issue AS b USING (issue)
    WHERE s.rank <= 10
)

SELECT
    rank,
    issue,
    threads,
    during,
    baseline,
    during / nullif(baseline, 0)                                AS lift,
    during / threads                                            AS share,
    row_number() OVER (ORDER BY during >= 15 DESC,
                                during / nullif(baseline, 0) DESC NULLS LAST,
                                during DESC)                    AS lift_rank
FROM top10;


CREATE OR REPLACE TABLE incident_summary AS
SELECT
    (SELECT count(*) FROM incidents)                                        AS count,
    (SELECT count(*) FILTER (WHERE impact = 'minor')    FROM incidents)     AS minor,
    (SELECT count(*) FILTER (WHERE impact = 'major')    FROM incidents)     AS major,
    (SELECT count(*) FILTER (WHERE impact = 'critical') FROM incidents)     AS critical,
    (SELECT count(*) FILTER (WHERE impact NOT IN ('minor', 'major', 'critical'))
       FROM incidents)                                                      AS other_impact,
    getvariable('incident_hours')                                           AS hours,
    (SELECT count(*) FILTER (WHERE is_during) FROM incident_threads)        AS all_during,
    (SELECT coalesce(sum(baseline_weight), 0) FROM incident_threads)        AS all_baseline,
    (SELECT sum(epoch(w_end - w_start)) / 3600 FROM incident_windows)       AS window_hours;
