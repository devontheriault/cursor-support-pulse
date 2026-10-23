-- 04_docs.sql
-- Is there a docs page for each top-10 issue, and do staff use it?
--   linked    staff linked a /docs page in >= 20% of the issue's threads
--             (url = the page they linked most)
--   unlinked  label.py docs found a matching page, but staff rarely link it
--   missing   label.py docs found no matching page
--   unknown   not matched yet (out/doc_matches.json absent or stale)
--
-- Set by build.py:
--   doc_matches    the text of out/doc_matches.json, or '{}' before it exists:
--                  {"<issue>": {"url": "https://cursor.com/docs/..." | null, "reason": "..."}}


CREATE OR REPLACE TABLE top_docs AS
WITH

matches AS (
    SELECT
        m.entry.key              AS issue,
        m.entry.value ->> 'url'  AS url
    FROM unnest(map_entries(
        getvariable('doc_matches')::JSON::MAP(VARCHAR, JSON)
    )) AS m(entry)
)

SELECT
    s.rank,
    s.issue,
    i.linked_share,
    CASE
        WHEN i.linked_share >= 0.2  THEN 'linked'
        WHEN m.issue IS NULL        THEN 'unknown'
        WHEN m.url IS NOT NULL      THEN 'unlinked'
        ELSE                             'missing'
    END AS status,
    CASE
        WHEN i.linked_share >= 0.2  THEN i.top_doc
        ELSE m.url                       -- null for missing and unknown
    END AS url
FROM scores AS s
JOIN issues AS i USING (issue)
LEFT JOIN matches AS m USING (issue)
WHERE s.rank <= 10
ORDER BY s.rank;
