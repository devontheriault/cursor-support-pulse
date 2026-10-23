-- 03_scores.sql
-- Rank issues by four equally weighted parts, each min-max scaled to 0-1
-- across every issue except Other (the catch-all is never ranked):
--   frequency   threads                  how often it comes up
--   breadth     users + likes            how many people it reaches
--   staffCost   staff posts              how much staff time it takes
--   negativity  -(average sentiment)     how frustrated people are
-- score = the mean of the four parts.


CREATE OR REPLACE TABLE scores AS
WITH

parts AS (
    SELECT
        issue,
        threads,
        threads                  AS frequency,
        users + likes            AS breadth,
        staff_posts              AS staff_cost,
        -coalesce(sentiment, 0)  AS negativity     -- unlabeled sentiment reads as neutral
    FROM issues
    WHERE issue <> 'Other'
),

-- (x - min) / (max - min). A part with no spread at all scales to 0
-- rather than dividing by zero.
scaled AS (
    SELECT
        issue,
        threads,
        coalesce((frequency - min(frequency) OVER ())
            / nullif(max(frequency) OVER () - min(frequency) OVER (), 0), 0)    AS frequency,
        coalesce((breadth - min(breadth) OVER ())
            / nullif(max(breadth) OVER () - min(breadth) OVER (), 0), 0)        AS breadth,
        coalesce((staff_cost - min(staff_cost) OVER ())
            / nullif(max(staff_cost) OVER () - min(staff_cost) OVER (), 0), 0)  AS staff_cost,
        coalesce((negativity - min(negativity) OVER ())
            / nullif(max(negativity) OVER () - min(negativity) OVER (), 0), 0)  AS negativity
    FROM parts
)

SELECT
    row_number() OVER (ORDER BY score DESC, threads DESC, issue) AS rank,
    *
FROM (
    SELECT
        issue,
        threads,
        frequency,
        breadth,
        staff_cost,
        negativity,
        (frequency + breadth + staff_cost + negativity) / 4 AS score
    FROM scaled
)
ORDER BY rank;
