/*
================================================================================
  ANALYSIS 4 — Feature → Revenue Correlation
================================================================================
  Author  : GTM Analytics — Downstream Optimization Layer
  Purpose : Identify which product features correlate most strongly with
            expansion revenue — and which correlate with churn.
            Gives CSMs a data-backed narrative for QBRs and upsell conversations.
  Patterns: Two-level aggregation (user × feature → feature rollup),
            HAVING filter, derived net_value_score, sorted ranking
  Output  : One row per feature with expansion rate, churn rate, net score
  Tableau : Scatter plot (churn % vs expansion %) + net_value_score bar chart
================================================================================

  NET VALUE SCORE = expansion_rate_pct − churn_rate_pct
  Higher = feature that reliably predicts expansion AND protects from churn
*/

-- Step 1: Compute per-user engagement metrics for each feature
WITH feature_per_user AS (
    SELECT
        e.feature_name,
        e.user_id,
        COUNT(*)                               AS event_count,
        ROUND(AVG(e.success) * 100, 1)         AS success_rate,
        ROUND(AVG(e.latency_ms), 0)            AS avg_latency_ms,
        ROUND(AVG(e.duration_ms), 0)           AS avg_duration_ms,
        COUNT(DISTINCT DATE(e.ts))             AS active_days_using_feature
    FROM events e
    GROUP BY e.feature_name, e.user_id
)

-- Step 2: Roll up to feature level; join user outcomes
SELECT
    f.feature_name,

    -- Reach
    COUNT(DISTINCT f.user_id)                              AS users_using_feature,
    ROUND(AVG(f.event_count), 1)                          AS avg_events_per_user,
    ROUND(AVG(f.active_days_using_feature), 1)            AS avg_active_days,

    -- Outcomes
    ROUND(AVG(u.expansion_event) * 100, 1)                AS expansion_rate_pct,
    ROUND(AVG(u.churned_90d)     * 100, 1)                AS churn_rate_pct,

    -- Quality signals
    ROUND(AVG(f.success_rate), 1)                         AS avg_success_rate,
    ROUND(AVG(f.avg_latency_ms), 0)                       AS avg_latency_ms,
    ROUND(AVG(f.avg_duration_ms), 0)                      AS avg_duration_ms,

    -- Composite value signal
    ROUND(AVG(u.expansion_event) * 100
        - AVG(u.churned_90d)     * 100, 1)                AS net_value_score,

    -- Effective adoption (reach × quality)
    ROUND(
        COUNT(DISTINCT f.user_id) * AVG(f.success_rate) / 100,
    0)                                                    AS effective_adoption

FROM feature_per_user f
JOIN  users u ON f.user_id = u.user_id
GROUP BY f.feature_name
HAVING COUNT(DISTINCT f.user_id) >= 50        -- minimum sample size for reliability
ORDER BY net_value_score DESC;

/*
================================================================================
  CSM INSIGHT
  -----------
  QBR Talking Points (data-backed narratives for CSMs):

  High net_value_score features:
    → "Clients actively using [Feature X] are [N]× more likely to expand
       than your average user — let's make sure your team is set up."

  High churn_rate features with low success_rate:
    → "We're seeing some friction with [Feature Y] — latency is high and
       success rate is below average. Let me connect you with our product team."

  Low effective_adoption, high net_value_score:
    → "There's a feature your power users love that your team hasn't explored.
       It's strongly correlated with customers staying longer — worth a demo."
================================================================================
*/
