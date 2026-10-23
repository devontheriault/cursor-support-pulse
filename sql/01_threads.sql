-- 01_threads.sql
-- One row per in-scope forum thread: the unit every later step aggregates.
--
-- Set by build.py:
--   topics_glob    raw/topics/*.json, one Discourse topic (with every post) per file
--   labels_path    out/labels.json: [{id, issue, sentiment}] from label.py assign
--   window_from    TIMESTAMP (UTC), first moment of the 90-day window
--   window_to      TIMESTAMP (UTC), end of the window (exclusive)
--
-- Scope (CONTRACT.md): Bug Reports (6) and Help (8), created inside the
-- window, not pinned, and opened by a user rather than by staff.


-- Read only the fields we use. Topic files carry ~80 keys whose shape drifts
-- between threads, so an explicit column list is faster and safer than
-- schema auto-detection over thousands of files.
CREATE OR REPLACE TEMP TABLE raw_topics AS
SELECT *
FROM read_json(
    getvariable('topics_glob'),
    columns = {
        id: 'BIGINT',
        title: 'VARCHAR',
        category_id: 'INTEGER',
        created_at: 'TIMESTAMP',
        pinned: 'BOOLEAN',
        tags: 'STRUCT(name VARCHAR)[]',
        views: 'INTEGER',
        like_count: 'INTEGER',   -- every reaction on every post counts as a like
        has_accepted_answer: 'BOOLEAN',
        post_stream: 'STRUCT(posts STRUCT(
            post_number INTEGER,
            post_type INTEGER,
            user_id BIGINT,
            staff BOOLEAN,
            accepted_answer BOOLEAN,
            link_counts STRUCT(url VARCHAR)[]
        )[])'
    }
);


-- One row per post. Only post_type 1 (a regular post) is conversation:
-- types 2-4 are moderator actions, "closed this topic" notices and whispers,
-- which would otherwise inflate staff effort.
CREATE OR REPLACE TEMP TABLE posts AS
SELECT
    t.id                                AS thread_id,
    p.post_number,
    p.user_id,
    coalesce(p.staff, false)            AS is_staff,
    coalesce(p.accepted_answer, false)  AS is_accepted,
    p.link_counts
FROM raw_topics AS t,
     unnest(t.post_stream.posts) AS u(p)
WHERE p.post_type = 1;


-- Each scope rule as its own flag, so build.py can print the funnel
-- (how many threads each rule removed) rather than one opaque count.
CREATE OR REPLACE TABLE scope AS
SELECT
    t.id,
    t.category_id IN (6, 8)                         AS in_category,
    t.created_at >= getvariable('window_from')
        AND t.created_at < getvariable('window_to') AS in_window,
    coalesce(t.pinned, false)                       AS is_pinned,
    coalesce(op.is_staff, false)                    AS staff_opened
FROM raw_topics AS t
LEFT JOIN posts AS op
    ON op.thread_id = t.id
   AND op.post_number = 1;


-- The LLM labels from label.py assign. Deduplicated defensively, and
-- sentiment clamped to the contract's -1..1.
CREATE OR REPLACE TEMP TABLE labels AS
SELECT
    id,
    any_value(issue)                                AS issue,
    greatest(-1, least(1, any_value(sentiment)))    AS sentiment
FROM read_json(
    getvariable('labels_path'),
    columns = {id: 'BIGINT', issue: 'VARCHAR', sentiment: 'DOUBLE'}
)
GROUP BY id;


-- A link to Cursor's docs or help center: the old docs.cursor.com host, or
-- cursor.com/docs and cursor.com/help with an optional www. and locale
-- (cursor.com/ja/docs). Group 1 is the section (empty on the old docs host,
-- which means docs), group 2 the page path without the query string or #anchor.
SET VARIABLE docs_url =
    '^https?://(?:www\.)?(?:docs\.cursor\.com|cursor\.com(?:/[a-z]{2}(?:-[a-z]{2,4})?)?/(docs|help))(/[^?#]*)?(?:[?#].*)?$';


CREATE OR REPLACE TABLE threads AS
WITH

post_stats AS (
    SELECT
        thread_id,
        count(*)                                    AS posts,
        count(*) FILTER (WHERE is_staff)            AS staff_posts,
        -- Users are counted by numeric id only; names never leave raw/.
        -- Ids <= 0 are Discourse's system and bot accounts.
        list(DISTINCT user_id ORDER BY user_id)
            FILTER (WHERE NOT is_staff AND user_id > 0) AS user_ids,
        bool_or(is_accepted)                        AS any_accepted
    FROM posts
    GROUP BY thread_id
),

-- Docs and help pages staff linked in the thread, one row per distinct page.
-- Normalized so one page counts once however it was written:
--   http://docs.cursor.com/agent/overview/   (the old docs host)
--   https://www.cursor.com/ja/docs/agent/overview?x=1#tools
--   both become https://cursor.com/docs/agent/overview
staff_doc_links AS (
    SELECT DISTINCT
        p.thread_id,
        'https://cursor.com/'
            || coalesce(nullif(regexp_extract(lower(link.url), getvariable('docs_url'), 1), ''), 'docs')
            || rtrim(regexp_extract(lower(link.url), getvariable('docs_url'), 2), '/') AS doc_url
    FROM posts AS p,
         unnest(p.link_counts) AS l(link)
    WHERE p.is_staff
      AND regexp_matches(lower(link.url), getvariable('docs_url'))
),

doc_links AS (
    SELECT thread_id, list(doc_url ORDER BY doc_url) AS doc_links
    FROM staff_doc_links
    GROUP BY thread_id
)

SELECT
    t.id,
    CASE t.category_id WHEN 6 THEN 'Bug Reports' WHEN 8 THEN 'Help' END AS category,
    t.created_at,
    t.title,                                         -- out/ only, never data.js
    [tag.name FOR tag IN coalesce(t.tags, [])]       AS tags,
    -- A thread crawled after labeling has no label yet; it still counts
    -- toward the totals, under Other, which is never ranked.
    coalesce(l.issue, 'Other')                       AS issue,
    l.sentiment,
    l.id IS NOT NULL                                 AS is_labeled,
    coalesce(ps.posts, 0)                            AS posts,
    coalesce(ps.user_ids, [])                        AS user_ids,
    len(coalesce(ps.user_ids, []))                   AS users,
    coalesce(t.like_count, 0)                        AS likes,
    coalesce(t.views, 0)                             AS views,
    coalesce(ps.staff_posts, 0)                      AS staff_posts,
    coalesce(t.has_accepted_answer, false)
        OR coalesce(ps.any_accepted, false)          AS solved,
    coalesce(d.doc_links, [])                        AS doc_links
FROM raw_topics AS t
JOIN scope AS s USING (id)
LEFT JOIN post_stats AS ps ON ps.thread_id = t.id
LEFT JOIN doc_links  AS d  ON d.thread_id  = t.id
LEFT JOIN labels     AS l  ON l.id         = t.id
WHERE s.in_category
  AND s.in_window
  AND NOT s.is_pinned
  AND NOT s.staff_opened;
