-- put this into BigQuery

SQL:
-- ============================================================
-- r/AskScience
-- READ-ONLY TOPIC-MATCHED PREFERENCE PAIRS
--
-- TARGET: up to 10,000 distinct preference pairs
--
-- DATA FACTS FROM DIAGNOSTIC:
--   usable posts:       7,524
--   preferred posts:    6,225   (upvote_ratio >= 0.80)
--   nonpreferred posts:   547   (upvote_ratio <= 0.50)
--
-- Because only 547 nonpreferred posts exist, controlled post
-- reuse is necessary to reach 10,000 distinct PAIRS.
--
-- REUSE LIMITS:
--   preferred post    <= 2 pairs
--   nonpreferred post <= 25 pairs
--
-- IMPORTANT:
--   This query is READ ONLY.
--   It creates NO tables, models, views, or other objects.
-- ============================================================


WITH target_posts AS (

  SELECT
    p.id AS post_id,
    s.name AS subreddit_name,
    p.title,
    p.body,
    p.upvote_ratio,
    p.created_at,
    p.permalink,

    EXTRACT(YEAR FROM p.created_at) AS post_year,
    EXTRACT(MONTH FROM p.created_at) AS post_month,
    EXTRACT(DAYOFWEEK FROM p.created_at) AS day_of_week,

    EXTRACT(DAYOFWEEK FROM p.created_at) IN (1, 7)
      AS is_weekend,

    CASE
      WHEN EXTRACT(HOUR FROM p.created_at) BETWEEN 5 AND 11
        THEN 'morning'

      WHEN EXTRACT(HOUR FROM p.created_at) BETWEEN 12 AND 17
        THEN 'afternoon'

      WHEN EXTRACT(HOUR FROM p.created_at) BETWEEN 18 AND 23
        THEN 'evening'

      ELSE 'night'
    END AS time_of_day

  FROM
    `rddt-eng-rfrexternal1-prod.mock_data_external.posts` AS p

  JOIN
    `rddt-eng-rfrexternal1-prod.mock_data_external.subreddits` AS s
      ON p.subreddit_id = s.id

  WHERE
    LOWER(s.name) = 'askscience'

    -- --------------------------------------------------------
    -- BASIC USABILITY FILTERS
    -- --------------------------------------------------------

    AND p.title IS NOT NULL
    AND TRIM(p.title) != ''

    AND p.body IS NOT NULL
    AND TRIM(p.body) != ''

    AND LOWER(TRIM(p.body)) NOT IN (
      '[deleted]',
      '[removed]',
      'deleted',
      'removed'
    )

    AND p.upvote_ratio IS NOT NULL
    AND p.created_at IS NOT NULL

    -- Remove clearly link-heavy / spam-like posts.
    AND ARRAY_LENGTH(
      REGEXP_EXTRACT_ALL(
        LOWER(CONCAT(p.title, ' ', p.body)),
        r'https?://'
      )
    ) < 3
),


-- ============================================================
-- TOKENIZE EACH POST FOR TOPIC/CONTENT MATCHING
--
-- Everything here exists only temporarily during the query.
-- Nothing is written back to BigQuery.
-- ============================================================

tokenized_posts AS (

  SELECT
    *,

    -- --------------------------------------------------------
    -- TITLE TOKENS
    --
    -- AskScience titles tend to describe the central scientific
    -- topic very clearly, so title content receives more weight
    -- later in the similarity score.
    -- --------------------------------------------------------

    ARRAY(
      SELECT DISTINCT token

      FROM UNNEST(
        REGEXP_EXTRACT_ALL(
          LOWER(title),
          r'[a-z][a-z0-9]{2,}'
        )
      ) AS token

      WHERE token NOT IN (

        'the', 'and', 'that', 'this', 'with', 'from',
        'for', 'are', 'was', 'were', 'have', 'has',
        'had', 'would', 'could', 'should', 'can',
        'does', 'did', 'doing', 'what', 'why',
        'when', 'where', 'which', 'who', 'how',
        'into', 'about', 'than', 'then', 'there',
        'their', 'they', 'them', 'you', 'your',
        'our', 'out', 'all', 'any', 'some',
        'more', 'most', 'much', 'many', 'just',
        'really', 'actually', 'something', 'anything',
        'question', 'questions', 'askscience',
        'isn', 'aren', 'wasn', 'weren', 'don',
        'doesn', 'didn', 'won', 'wouldn', 'couldn'

      )

    ) AS title_tokens,


    -- --------------------------------------------------------
    -- BODY TOKENS
    --
    -- First 2,500 characters are used to keep the SQL workload
    -- reasonable while still capturing the post's main content.
    -- --------------------------------------------------------

    ARRAY(
      SELECT DISTINCT token

      FROM UNNEST(
        REGEXP_EXTRACT_ALL(
          LOWER(SUBSTR(body, 1, 2500)),
          r'[a-z][a-z0-9]{2,}'
        )
      ) AS token

      WHERE token NOT IN (

        'the', 'and', 'that', 'this', 'with', 'from',
        'for', 'are', 'was', 'were', 'have', 'has',
        'had', 'would', 'could', 'should', 'can',
        'does', 'did', 'doing', 'what', 'why',
        'when', 'where', 'which', 'who', 'how',
        'into', 'about', 'than', 'then', 'there',
        'their', 'they', 'them', 'you', 'your',
        'our', 'out', 'all', 'any', 'some',
        'more', 'most', 'much', 'many', 'just',
        'really', 'actually', 'something', 'anything',
        'question', 'questions', 'askscience',
        'isn', 'aren', 'wasn', 'weren', 'don',
        'doesn', 'didn', 'won', 'wouldn', 'couldn'

      )

    ) AS body_tokens

  FROM target_posts
),


-- ============================================================
-- PREFERRED POSTS
-- ============================================================

preferred_posts AS (

  SELECT *

  FROM tokenized_posts

  WHERE upvote_ratio >= 0.80
),


-- ============================================================
-- NONPREFERRED POSTS
-- ============================================================

nonpreferred_posts AS (

  SELECT *

  FROM tokenized_posts

  WHERE upvote_ratio <= 0.50
),


-- ============================================================
-- MAKE POSSIBLE PREFERENCE PAIRS
--
-- We permit a maximum separation of 14 days.
--
-- This is deliberately much looser than the original SQL
-- because your professor said posting-time matching can be
-- relaxed when necessary.
--
-- Actual ranking strongly favors much closer pairs.
-- ============================================================

candidate_pairs_raw AS (

  SELECT

    -- --------------------------------------------------------
    -- PREFERRED POST
    -- --------------------------------------------------------

    preferred.post_id
      AS preferred_post_id,

    preferred.title
      AS preferred_post_title,

    preferred.body
      AS preferred_post_body,

    preferred.upvote_ratio
      AS preferred_upvote_ratio,

    preferred.created_at
      AS preferred_post_created_at,

    preferred.permalink
      AS preferred_post_permalink,


    -- --------------------------------------------------------
    -- NONPREFERRED POST
    -- --------------------------------------------------------

    nonpreferred.post_id
      AS nonpreferred_post_id,

    nonpreferred.title
      AS nonpreferred_post_title,

    nonpreferred.body
      AS nonpreferred_post_body,

    nonpreferred.upvote_ratio
      AS nonpreferred_upvote_ratio,

    nonpreferred.created_at
      AS nonpreferred_post_created_at,

    nonpreferred.permalink
      AS nonpreferred_post_permalink,


    -- --------------------------------------------------------
    -- TOKEN ARRAYS
    -- --------------------------------------------------------

    preferred.title_tokens
      AS preferred_title_tokens,

    nonpreferred.title_tokens
      AS nonpreferred_title_tokens,

    preferred.body_tokens
      AS preferred_body_tokens,

    nonpreferred.body_tokens
      AS nonpreferred_body_tokens,


    -- --------------------------------------------------------
    -- PREFERENCE SIGNAL
    -- --------------------------------------------------------

    preferred.upvote_ratio
      - nonpreferred.upvote_ratio
      AS upvote_ratio_gap,


    -- --------------------------------------------------------
    -- TEMPORAL DIFFERENCE
    -- --------------------------------------------------------

    ABS(
      TIMESTAMP_DIFF(
        preferred.created_at,
        nonpreferred.created_at,
        MINUTE
      )
    ) / 60.0
      AS hours_apart,


    -- --------------------------------------------------------
    -- SAME BROAD TIME OF DAY
    --
    -- Preferred during ranking, but NOT required.
    -- --------------------------------------------------------

    preferred.time_of_day
      = nonpreferred.time_of_day
      AS same_time_of_day,


    preferred.time_of_day
      AS preferred_time_of_day,

    nonpreferred.time_of_day
      AS nonpreferred_time_of_day,


    -- --------------------------------------------------------
    -- DIAGNOSTIC TEMPORAL INFORMATION
    -- --------------------------------------------------------

    preferred.day_of_week
      AS preferred_day_of_week,

    nonpreferred.day_of_week
      AS nonpreferred_day_of_week,

    preferred.is_weekend
      AS preferred_is_weekend,

    nonpreferred.is_weekend
      AS nonpreferred_is_weekend


  FROM preferred_posts AS preferred

  JOIN nonpreferred_posts AS nonpreferred

    ON preferred.post_id != nonpreferred.post_id

    -- --------------------------------------------------------
    -- MAXIMUM TEMPORAL RELAXATION = 14 DAYS
    -- --------------------------------------------------------

    AND nonpreferred.created_at BETWEEN

      TIMESTAMP_SUB(
        preferred.created_at,
        INTERVAL 30 DAY
      )

      AND

      TIMESTAMP_ADD(
        preferred.created_at,
        INTERVAL 30 DAY
      )


  WHERE

    -- --------------------------------------------------------
    -- KEEP ORIGINAL PROFESSOR-APPROVED RATIO GAP
    -- --------------------------------------------------------

    preferred.upvote_ratio
      - nonpreferred.upvote_ratio >= 0.30
),


-- ============================================================
-- TEMPORAL TIERS
--
-- 1 = ideal
-- 2-5 = progressively relaxed when necessary
-- ============================================================

temporal_candidates AS (

  SELECT
    *,

    CASE

      WHEN hours_apart <= 6
        THEN 1

      WHEN hours_apart <= 24
        THEN 2

      WHEN hours_apart <= 72
        THEN 3

      WHEN hours_apart <= 168
        THEN 4

      WHEN hours_apart <= 336
        THEN 5

      ELSE 6

    END AS temporal_tier,


    CASE

      WHEN hours_apart <= 6
        THEN '0-6 hours'

      WHEN hours_apart <= 24
        THEN '6-24 hours'

      WHEN hours_apart <= 72
        THEN '1-3 days'

      WHEN hours_apart <= 168
        THEN '3-7 days'

      WHEN hours_apart <= 336
        THEN '7-14 days'

      ELSE '14-30 days'

    END AS temporal_window

  FROM candidate_pairs_raw
),


-- ============================================================
-- CALCULATE TITLE/BODY WORD OVERLAP
--
-- Shared meaningful vocabulary acts as our read-only proxy for
-- semantic/topic similarity.
--
-- No AI model or embedding model is created or called here.
-- ============================================================

topic_overlap_counts AS (

  SELECT
    *,

    -- Shared title terms
    (
      SELECT COUNT(DISTINCT p_token)

      FROM UNNEST(preferred_title_tokens) AS p_token

      JOIN UNNEST(nonpreferred_title_tokens) AS n_token
        ON p_token = n_token

    ) AS shared_title_tokens,


    -- Shared body terms
    (
      SELECT COUNT(DISTINCT p_token)

      FROM UNNEST(preferred_body_tokens) AS p_token

      JOIN UNNEST(nonpreferred_body_tokens) AS n_token
        ON p_token = n_token

    ) AS shared_body_tokens,


    ARRAY_LENGTH(preferred_title_tokens)
      AS preferred_title_token_count,

    ARRAY_LENGTH(nonpreferred_title_tokens)
      AS nonpreferred_title_token_count,

    ARRAY_LENGTH(preferred_body_tokens)
      AS preferred_body_token_count,

    ARRAY_LENGTH(nonpreferred_body_tokens)
      AS nonpreferred_body_token_count


  FROM temporal_candidates
),


-- ============================================================
-- JACCARD-LIKE TOPIC SIMILARITY
--
-- intersection / union
--
-- union =
--   preferred tokens
--   + nonpreferred tokens
--   - shared tokens
-- ============================================================

topic_similarity_components AS (

  SELECT
    *,

    SAFE_DIVIDE(

      shared_title_tokens,

      preferred_title_token_count
        + nonpreferred_title_token_count
        - shared_title_tokens

    ) AS title_topic_similarity,


    SAFE_DIVIDE(

      shared_body_tokens,

      preferred_body_token_count
        + nonpreferred_body_token_count
        - shared_body_tokens

    ) AS body_topic_similarity


  FROM topic_overlap_counts
),


-- ============================================================
-- COMBINED TOPIC SCORE
--
-- 65% TITLE
-- 35% BODY
--
-- AskScience titles usually contain the central scientific
-- subject/question, so title similarity receives more weight.
-- ============================================================

scored_pairs AS (

  SELECT
    *,

    (
      0.65 * COALESCE(title_topic_similarity, 0)
      +
      0.35 * COALESCE(body_topic_similarity, 0)
    ) AS topic_similarity,


    -- --------------------------------------------------------
    -- Useful diagnostic indicating whether there was any
    -- meaningful vocabulary overlap at all.
    -- --------------------------------------------------------

    (
      shared_title_tokens > 0
      OR shared_body_tokens > 0
    ) AS has_topic_overlap


  FROM topic_similarity_components
),


-- ============================================================
-- KEEP A LARGE SET OF GOOD OPTIONS FOR EACH PREFERRED POST
--
-- IMPORTANT:
--
-- Do NOT immediately reduce each preferred post to only one
-- possible match.
--
-- We need alternative low-upvote matches because only 547
-- nonpreferred posts exist and each one has a reuse cap.
--
-- Keep top 20 candidate matches per preferred post.
--
-- PRIMARY criterion:
--   topic/content similarity
--
-- SECONDARY:
--   temporal proximity
--
-- THIRD:
--   same broad time of day
-- ============================================================

preferred_candidate_pool AS (

  SELECT *

  FROM scored_pairs

  QUALIFY

    ROW_NUMBER() OVER (

      PARTITION BY preferred_post_id

      ORDER BY

        temporal_tier ASC,
        
        topic_similarity DESC,
        
        same_time_of_day DESC,
        
        hours_apart ASC,

        nonpreferred_post_id

    ) <= 40
),


-- ============================================================
-- CONTROL NONPREFERRED-POST REUSE
--
-- A low-upvote post may appear in multiple comparisons because
-- there are only 547 such posts.
--
-- But it may appear in NO MORE THAN 25 candidate pairs.
--
-- This prevents a tiny number of low-rated posts from
-- dominating the entire experiment.
-- ============================================================

bounded_nonpreferred AS (

  SELECT *

  FROM preferred_candidate_pool

  QUALIFY

    ROW_NUMBER() OVER (

      PARTITION BY nonpreferred_post_id

      ORDER BY

        temporal_tier ASC,
        
        topic_similarity DESC,
        
        same_time_of_day DESC,
        
        hours_apart ASC,

        preferred_post_id

    ) <= 30
),


-- ============================================================
-- CONTROL PREFERRED-POST REUSE
--
-- Each preferred post may appear in at most TWO comparisons.
-- ============================================================

bounded_both_sides AS (

  SELECT *

  FROM bounded_nonpreferred

  QUALIFY

    ROW_NUMBER() OVER (

      PARTITION BY preferred_post_id

      ORDER BY

        temporal_tier ASC,
        
        topic_similarity DESC,
        
        same_time_of_day DESC,
        
        hours_apart ASC,

        nonpreferred_post_id

    ) <= 2
),


-- ============================================================
-- EXTRA SAFETY CHECK
--
-- Re-apply the nonpreferred <=25 constraint after preferred-side
-- selection.
--
-- It should already hold, but this makes the final rule explicit.
-- ============================================================

final_pair_pool AS (

  SELECT *

  FROM bounded_both_sides

  QUALIFY

    ROW_NUMBER() OVER (

      PARTITION BY nonpreferred_post_id

      ORDER BY

        temporal_tier ASC,
        
        topic_similarity DESC,
        
        same_time_of_day DESC,
        
        hours_apart ASC,

        preferred_post_id

    ) <= 30
),


-- ============================================================
-- RECORD HOW LARGE THE VALID POOL IS BEFORE SAMPLING
--
-- This lets you immediately see whether the matching procedure
-- actually generated at least 10,000 allowable distinct pairs.
-- ============================================================

pair_pool_with_count AS (

  SELECT
    *,

    COUNT(*) OVER ()
      AS available_pair_pool_size

  FROM final_pair_pool
),


-- ============================================================
-- FINAL 10,000
--
-- The reuse controls and topical matching have already happened.
-- We randomize only at the final sampling stage.
-- ============================================================

sampled_pairs AS (

  SELECT *

  FROM pair_pool_with_count

  ORDER BY RAND()

  LIMIT 10000
)


-- ============================================================
-- FINAL OUTPUT
-- ============================================================

SELECT

  ROW_NUMBER() OVER (
    ORDER BY RAND()
  ) AS pair_id,


  -- ----------------------------------------------------------
  -- PREFERRED POST
  -- ----------------------------------------------------------

  preferred_post_id,

  preferred_post_title,

  preferred_post_body,

  preferred_upvote_ratio,

  preferred_post_created_at,

  preferred_post_permalink,


  -- ----------------------------------------------------------
  -- NONPREFERRED POST
  -- ----------------------------------------------------------

  nonpreferred_post_id,

  nonpreferred_post_title,

  nonpreferred_post_body,

  nonpreferred_upvote_ratio,

  nonpreferred_post_created_at,

  nonpreferred_post_permalink,


  -- ----------------------------------------------------------
  -- PREFERENCE SIGNAL
  -- ----------------------------------------------------------

  upvote_ratio_gap,


  -- ----------------------------------------------------------
  -- TOPIC / CONTENT MATCHING
  -- ----------------------------------------------------------

  topic_similarity,

  title_topic_similarity,

  body_topic_similarity,

  shared_title_tokens,

  shared_body_tokens,

  has_topic_overlap,


  -- ----------------------------------------------------------
  -- TEMPORAL MATCHING
  -- ----------------------------------------------------------

  hours_apart,

  temporal_tier,

  temporal_window,

  same_time_of_day,

  preferred_time_of_day,

  nonpreferred_time_of_day,


  -- ----------------------------------------------------------
  -- DIAGNOSTICS
  --
  -- These fields are NOT matching requirements anymore.
  -- ----------------------------------------------------------

  preferred_day_of_week,

  nonpreferred_day_of_week,

  preferred_is_weekend,

  nonpreferred_is_weekend,


  -- ----------------------------------------------------------
  -- IMPORTANT:
  --
  -- This will show the size of the eligible pair pool BEFORE
  -- LIMIT 10000.
  --
  -- If this number >= 10000, the experiment successfully had
  -- enough allowable pairs.
  -- ----------------------------------------------------------

  available_pair_pool_size


FROM sampled_pairs

ORDER BY pair_id;
