-- 02_issues.sql
-- One row per issue: how often it comes up, how many people it reaches,
-- what it costs staff, and how it feels. Built on threads (01).


CREATE OR REPLACE TABLE issues AS
WITH

-- Distinct people across the whole issue: someone who posts in three
-- threads about the same problem is one affected user, not three.
issue_users AS (
    SELECT issue, count(DISTINCT user_id) AS users
    FROM threads, unnest(user_ids) AS u(user_id)
    GROUP BY issue
),

-- For each docs page, the number of the issue's threads where staff
-- linked it (doc_links is already distinct per thread).
doc_pages AS (
    SELECT issue, doc_url, count(*) AS threads_linking
    FROM threads, unnest(doc_links) AS d(doc_url)
    GROUP BY issue, doc_url
),

top_doc AS (
    SELECT issue, doc_url
    FROM doc_pages
    QUALIFY row_number() OVER (
        PARTITION BY issue ORDER BY threads_linking DESC, doc_url
    ) = 1
),

-- A thread's engagement: the people in it plus the likes they gave.
-- Ties fall back to views, then the oldest thread, so reruns are stable.
ranked_threads AS (
    SELECT
        *,
        row_number() OVER (
            PARTITION BY issue ORDER BY users + likes DESC, views DESC, id
        ) AS engagement_rank
    FROM threads
)

SELECT
    t.issue,
    count(*)                                         AS threads,
    coalesce(any_value(iu.users), 0)                 AS users,
    sum(t.likes)                                     AS likes,
    sum(t.staff_posts)                               AS staff_posts,
    avg(t.sentiment)                                 AS sentiment,
    avg(CASE WHEN len(t.doc_links) > 0 THEN 1 ELSE 0 END) AS linked_share,
    any_value(td.doc_url)                            AS top_doc,
    any_value(t.id) FILTER (WHERE t.engagement_rank = 1)  AS example_id,
    -- The five most-engaged titles: context for label.py docs. out/ only.
    list(t.title ORDER BY t.engagement_rank)
        FILTER (WHERE t.engagement_rank <= 5)        AS sample_titles
FROM ranked_threads AS t
LEFT JOIN issue_users AS iu USING (issue)
LEFT JOIN top_doc     AS td USING (issue)
GROUP BY t.issue;
