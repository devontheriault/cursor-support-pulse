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
            link_counts STRUCT(url VARCHAR)[],
            cooked VARCHAR
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
    p.link_counts,
    CASE WHEN p.post_number = 1 THEN p.cooked END AS cooked
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


-- The Cursor app version the reporter is on, as major.minor ('3.21'), from
-- the first post. The Bug Reports template has a "Version Information"
-- section; what people put there, checked by hand on real threads:
--   * Cursor's About dialog, pasted: "Version: 3.21.4 (user setup)" then
--     "VSCode Version: 1.105.1" / "Commit: ..." / "Electron: ..." lines.
--   * Free text marking it as Cursor's: "Cursor 3.23.23", "Cursor IDE
--     3.13.25", "Cursor Mac Desktop: 3.20.21", "cursor-server 3.22.12",
--     "IDE: 3.18.9", a "Version: 3.14.7 · OS: macOS" line, or a build
--     suffix: "3.18.9 (user setup)", "(system setup)", "(Universal)",
--     "(ARM64)", "(commit ae3a2b7)".
--   * Other products' versions, which must not count: Grok Bot's own About
--     dialog ("Version: 0.71.2" then "Built: ..."), the CLI
--     ("Version: 2026.10.16-e3cb207"), @cursor/sdk 1.0.x, the iOS app, and
--     "VSCode Version: 1.128.0", the editor base inside the IDE.
--   * Bare numbers ("3.17.8" alone): left out. Usually the IDE, but nothing
--     in the text says so, and Grok Bot and SDK reports look the same.
-- So a version counts when it is
--   1. an About-dialog "Version:" line (at a line start, so "VSCode
--      Version:" never matches) with a VSCode, Commit or Electron line within
--      the next few lines, anywhere in the post; or
--   2. inside the Version Information section, a version named as Cursor's
--      ("Cursor ... 3.20.21", not "Cursor iOS/CLI ..."); or
--   3. inside that section, a version with a desktop build suffix; or
--   4. inside that section, a "Version:"/"IDE:" line, unless the section
--      names another product (Grok, CLI, SDK, iOS, Android, JetBrains, or
--      Grok Bot's "Built:" and "Release Track:" lines).
-- The About paste arrives as <br>-separated lines or a code block, so
-- structure is read line by line.
CREATE OR REPLACE TEMP TABLE app_versions AS
WITH

-- Block tags and <br> become line breaks, inline tags (<strong>, <code>)
-- vanish, so "Cursor version: <strong>3.13.10</strong>" stays one line.
html_text AS (
    SELECT
        thread_id,
        cooked,
        '</?(?:p|br|li|ul|ol|div|pre|blockquote|h[1-6]|tr|td|th|table|hr)\b[^>]*>' AS block_tag
    FROM posts
    WHERE post_number = 1 AND cooked IS NOT NULL
),

first_posts AS (
    SELECT
        thread_id,
        regexp_replace(regexp_replace(cooked, block_tag, chr(10), 'g'), '<[^>]+>', '', 'g') AS body,
        regexp_replace(regexp_replace(
            regexp_extract(cooked, '(?s)version-information[^>]*>.*?</h3>(.*?)(?:<h3|$)', 1),
            block_tag, chr(10), 'g'), '<[^>]+>', '', 'g')                                  AS section
    FROM html_text
),

candidates AS (
    SELECT
        thread_id,
        nullif(regexp_extract(body,
            '(?m)^[ \t]*Version:[ \t]*v?(\d+\.\d+)\.\d+[^\n]*\n(?:[^\n]*\n){0,3}?[^\n]*(?:VS ?Code|Commit:|Electron:)', 1), '')
                                                                    AS about_dialog,
        -- "Cursor 3.23.23", "Cursor Mac Desktop: 3.20.21", "cursor-server
        -- 3.22.12", or a label and value on two lines ("Cursor Version" /
        -- "3.24.18"). The words between are kept to reject "Cursor iOS
        -- v1.4.0", "Cursor CLI: 3.0.9" and "Cursor on macOS 26.6.1"; a one-
        -- or two-digit major keeps the CLI's date versions (2026.08.25) out,
        -- and a 4+ digit build number in brackets marks the iOS app
        -- ("Cursor v1.6.1 (39021)").
        regexp_extract(section, '(?i)\bcursor\b([^\d]{0,25}?)v?(\d{1,2}\.\d+)\.\d+((?:\.\d+)?\s*\(\d{4,}\))?',
                       ['gap', 'version', 'ios_build'])
                                                                    AS named,
        regexp_matches(section, '(?i)grok|sdk|\bcli\b|\bios\b|iphone|android|jetbrains|built:|release track')
                                                                    AS names_other_product,
        -- a build suffix only Cursor's desktop app prints
        nullif(regexp_extract(section,
            '(?i)\b(\d+\.\d+)\.\d+\s*\((?:user setup|system setup|universal|arm64|x64|commit\b[^)]*)\)', 1), '')
                                                                    AS build_suffix,
        -- a line opening "Version: 3.14.7", "Version 3.14.7", "IDE: 3.18.9"
        nullif(regexp_extract(section, '(?im)^[ \t]*(?:IDE|Version)[ \t]*:?[ \t]*v?(\d{1,2}\.\d+)\.\d+', 1), '')
                                                                    AS version_line
    FROM first_posts
)

SELECT
    thread_id,
    coalesce(
        about_dialog,
        CASE WHEN named.ios_build = '' AND NOT regexp_matches(named.gap,
                      '(?i)ios|cli|sdk|agent|grok|android|jetbrains|mac|windows|darwin|linux|node|build|electron|chrom|code|extension')
             THEN nullif(named.version, '') END,
        build_suffix,
        -- A bare "Version:" line only counts when the section is about nothing else.
        CASE WHEN NOT names_other_product THEN version_line END
    )                                                               AS app_version
FROM candidates;


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
    coalesce(d.doc_links, [])                        AS doc_links,
    v.app_version                                    -- '3.21', or NULL if the post names none
FROM raw_topics AS t
JOIN scope AS s USING (id)
LEFT JOIN post_stats AS ps ON ps.thread_id = t.id
LEFT JOIN doc_links  AS d  ON d.thread_id  = t.id
LEFT JOIN labels     AS l  ON l.id         = t.id
LEFT JOIN app_versions AS v ON v.thread_id = t.id
WHERE s.in_category
  AND s.in_window
  AND NOT s.is_pinned
  AND NOT s.staff_opened;
