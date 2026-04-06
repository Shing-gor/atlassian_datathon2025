/*
================================================================================
  ANALYSIS 1 — MRR Waterfall & Revenue Momentum
================================================================================
  Author  : GTM Analytics — Downstream Optimization Layer
  Purpose : Track Monthly Recurring Revenue trends by plan tier.
            Identify where growth is accelerating and where revenue is leaking.
  Patterns: GROUP BY, LAG() window function, PARTITION BY, COALESCE
  Output  : One row per month × plan_tier with MRR, delta, and growth %
  Tableau : Use month on x-axis; total_mrr / mrr_delta for dual-axis line + bar
================================================================================
*/

-- Step 1: Aggregate raw billing to monthly MRR per tier
WITH monthly_mrr AS (
    SELECT
        month,
        plan_tier,
        ROUND(SUM(mrr), 2)                                          AS total_mrr,
        COUNT(DISTINCT user_id)                                     AS paying_accounts,

        -- ARPU for paying accounts only (excludes free $0 MRR)
        ROUND(AVG(CASE WHEN mrr > 0 THEN mrr END), 2)              AS arpu,

        -- Blended ARPU across all accounts in the tier
        ROUND(
            SUM(CASE WHEN mrr > 0 THEN mrr END)
            / NULLIF(COUNT(DISTINCT user_id), 0),
        2)                                                          AS blended_arpu
    FROM billing
    GROUP BY month, plan_tier
),

-- Step 2: LAG() computes prior-period MRR for delta and growth rate
mrr_with_lag AS (
    SELECT *,
        LAG(total_mrr) OVER (
            PARTITION BY plan_tier          -- independent window per tier
            ORDER BY month
        )                                                           AS prev_mrr
    FROM monthly_mrr
)

-- Step 3: Final output with delta and growth %
SELECT
    month,
    plan_tier,
    total_mrr,
    paying_accounts,
    arpu,
    blended_arpu,
    ROUND(total_mrr - COALESCE(prev_mrr, total_mrr), 2)           AS mrr_delta,
    CASE
        WHEN COALESCE(prev_mrr, 0) > 0
        THEN ROUND((total_mrr - prev_mrr) * 100.0 / prev_mrr, 2)
    END                                                            AS mrr_growth_pct
FROM mrr_with_lag
ORDER BY month, plan_tier;

/*
================================================================================
  CSM INSIGHT
  -----------
  • Rising mrr_delta = organic expansion momentum
  • Negative mrr_delta = churn exceeding new bookings (retention alert)
  • ARPU gap between tiers → upsell pricing conversation
================================================================================
*/
