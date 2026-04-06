/*
================================================================================
  ANALYSIS 6 — Acquisition Channel ROI
================================================================================
  Author  : GTM Analytics — Downstream Optimization Layer
  Purpose : Rank acquisition channel × industry combinations by risk-adjusted
            lifetime value. Answer: "which CAC dollar produces the most
            durable revenue?"
  Patterns: Lifetime MRR aggregation, RANK() window function,
            risk-adjusted LTV formula, multi-dimensional GROUP BY,
            HAVING for minimum statistical reliability
  Output  : Channel × industry ranked by risk-adjusted LTV
  Tableau : Heatmap (channel × industry) coloured by risk_adj_ltv
================================================================================

  RISK-ADJUSTED LTV FORMULA
  ──────────────────────────────────────────────────────────────────────────
  risk_adj_ltv = avg_lifetime_mrr × (1 − churn_rate)

  Logic: discounts raw lifetime revenue by the probability of churning.
  Channels with high raw LTV but high churn are penalised.
  Channels with moderate LTV but low churn float to the top.
*/

WITH

-- Step 1: Aggregate total and average lifetime MRR per user
lifetime_value AS (
    SELECT
        user_id,
        ROUND(SUM(mrr), 2)            AS lifetime_mrr,
        COUNT(DISTINCT month)         AS months_billed,
        ROUND(MAX(mrr), 2)            AS peak_monthly_mrr
    FROM billing
    GROUP BY user_id
)

-- Step 2: Join to user attributes; roll up to channel × industry
SELECT
    u.acquisition_channel,
    u.industry,
    u.region,

    COUNT(*)                                                     AS cohort_size,
    ROUND(AVG(l.lifetime_mrr), 2)                               AS avg_lifetime_mrr,
    ROUND(SUM(l.lifetime_mrr), 0)                               AS total_portfolio_mrr,
    ROUND(AVG(l.months_billed), 1)                              AS avg_months_billed,

    -- Churn and expansion rates
    ROUND(AVG(u.churned_90d)      * 100, 1)                     AS churn_rate_pct,
    ROUND(AVG(u.expansion_event)  * 100, 1)                     AS expansion_rate_pct,
    ROUND(AVG(u.downgraded)       * 100, 1)                     AS downgrade_rate_pct,

    -- Risk-Adjusted LTV: the key metric for budget allocation
    ROUND(
        AVG(l.lifetime_mrr) * (1.0 - AVG(u.churned_90d)),
    2)                                                           AS risk_adj_ltv,

    -- Net revenue momentum = expansion momentum − churn drag
    ROUND(
        AVG(u.expansion_event) * 100 - AVG(u.churned_90d) * 100,
    1)                                                           AS net_revenue_momentum,

    -- Global rank across all channel × industry combinations
    RANK() OVER (
        ORDER BY AVG(l.lifetime_mrr) * (1.0 - AVG(u.churned_90d)) DESC
    )                                                            AS ltv_rank,

    -- Rank within each acquisition channel only
    RANK() OVER (
        PARTITION BY u.acquisition_channel
        ORDER BY AVG(l.lifetime_mrr) * (1.0 - AVG(u.churned_90d)) DESC
    )                                                            AS rank_within_channel

FROM users u
LEFT JOIN lifetime_value l ON u.user_id = l.user_id
GROUP BY u.acquisition_channel, u.industry, u.region
HAVING COUNT(*) >= 30                   -- minimum cohort size for reliability
ORDER BY risk_adj_ltv DESC;

/*
================================================================================
  CSM INSIGHT
  -----------
  • Top ltv_rank combinations → increase CAC budget allocation
  • High churn_rate_pct segments → review onboarding quality for that channel
  • Low rank_within_channel but high cohort_size → volume ≠ value problem

  BUDGET REALLOCATION LOGIC:
    1. Identify segments where risk_adj_ltv is 2× the average
    2. Calculate how much additional volume that channel could absorb
    3. Present to marketing: "shift [X]% of [channel] spend from [low-LTV
       industry] to [high-LTV industry] — model projects [Y]% ARR uplift"

  COMMERCIAL ANALYST MINDSET:
    This query shifts the conversation from "which channel drives most leads?"
    to "which channel drives the most durable, expansion-ready revenue?" —
    a fundamentally different and more valuable question for the GTM team.
================================================================================
*/
