/*
================================================================================
  ANALYSIS 3 — Churn Early Warning System
================================================================================
  Author  : GTM Analytics — Downstream Optimization Layer
  Purpose : Surface currently-active accounts showing engagement decay signals
            that historically precede churn. Give CSMs a 30–60 day head start.
  Patterns: ROW_NUMBER() window function, conditional aggregation,
            month-over-month session delta, multi-table JOIN
  Output  : One row per active account with engagement_signal and risk_priority
  Tableau : Use engagement_signal as colour dimension; sort by avg_mrr DESC
================================================================================

  DECAY SIGNAL DEFINITIONS
  ┌────────────────────────┬─────────────────────────────────────────┐
  │ Signal                 │ Definition                              │
  ├────────────────────────┼─────────────────────────────────────────┤
  │ Gone Dark              │ Zero sessions in most recent month      │
  │ Rapid Decline          │ Sessions dropped > 50% MoM             │
  │ Mild Decline           │ Sessions dropped 25–50% MoM            │
  │ Stable                 │ Consistent or growing activity          │
  └────────────────────────┴─────────────────────────────────────────┘
*/

WITH

-- Step 1: Monthly session counts per user
user_monthly_sessions AS (
    SELECT
        user_id,
        SUBSTR(session_start, 1, 7)          AS month,
        COUNT(*)                             AS monthly_sessions
    FROM sessions
    GROUP BY user_id, SUBSTR(session_start, 1, 7)
),

-- Step 2: Rank months per user (most recent = rank 1)
-- Using ROW_NUMBER avoids slow correlated subqueries (O(n²))
ranked_months AS (
    SELECT
        user_id,
        month,
        monthly_sessions,
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY month DESC
        )                                    AS month_rank
    FROM user_monthly_sessions
),

-- Step 3: Pivot to get latest and prior-period session counts side by side
current_vs_prior AS (
    SELECT
        user_id,
        MAX(CASE WHEN month_rank = 1 THEN month            END) AS latest_month,
        MAX(CASE WHEN month_rank = 1 THEN monthly_sessions END) AS latest_sessions,
        MAX(CASE WHEN month_rank = 2 THEN monthly_sessions END) AS prev_sessions
    FROM ranked_months
    WHERE month_rank <= 2
    GROUP BY user_id
),

-- Step 4: Billing summary for revenue context
billing_summary AS (
    SELECT
        user_id,
        ROUND(AVG(mrr), 2)                   AS avg_mrr,
        ROUND(MAX(mrr), 2)                   AS peak_mrr,
        SUM(support_ticket_count)            AS total_tickets,
        SUM(invoices_overdue)                AS overdue_invoices
    FROM billing
    GROUP BY user_id
)

SELECT
    c.user_id,
    u.plan_tier,
    u.industry,
    u.company_size,
    u.region,
    u.acquisition_channel,
    b.avg_mrr,
    b.peak_mrr,
    b.total_tickets,
    b.overdue_invoices,
    c.latest_month,
    COALESCE(c.latest_sessions, 0)           AS latest_sessions,
    COALESCE(c.prev_sessions,   0)           AS prev_sessions,

    -- Month-over-month session change %
    ROUND(
        CASE
            WHEN COALESCE(c.prev_sessions, 0) > 0
            THEN (COALESCE(c.latest_sessions, 0) - c.prev_sessions) * 100.0
                 / c.prev_sessions
            ELSE 0
        END,
    1)                                       AS session_delta_pct,

    -- Decay signal classification
    CASE
        WHEN COALESCE(c.latest_sessions, 0) = 0
             THEN 'Gone Dark'
        WHEN COALESCE(c.latest_sessions, 0) < COALESCE(c.prev_sessions, 0) * 0.50
             THEN 'Rapid Decline'
        WHEN COALESCE(c.latest_sessions, 0) < COALESCE(c.prev_sessions, 0) * 0.75
             THEN 'Mild Decline'
        ELSE 'Stable'
    END                                      AS engagement_signal,

    -- Numeric priority for Tableau sort (1 = most urgent)
    CASE
        WHEN COALESCE(c.latest_sessions, 0) = 0                              THEN 1
        WHEN COALESCE(c.latest_sessions, 0) < COALESCE(c.prev_sessions,0)*0.50 THEN 2
        WHEN COALESCE(c.latest_sessions, 0) < COALESCE(c.prev_sessions,0)*0.75 THEN 3
        ELSE 4
    END                                      AS risk_priority

FROM current_vs_prior c
JOIN  users         u  ON c.user_id = u.user_id
LEFT JOIN billing_summary b ON c.user_id = b.user_id
WHERE u.churned_90d = 0           -- only flag currently-active accounts
ORDER BY risk_priority ASC, b.avg_mrr DESC;

/*
================================================================================
  CSM INSIGHT
  -----------
  • Gone Dark + high avg_mrr → immediate account manager escalation
  • Rapid Decline → 7-day personalised re-engagement campaign
  • Revenue rescued = SUM(avg_mrr) × save_rate (industry avg: 20–25%)
  • Rule of thumb: $1 on proactive retention saves $5 in re-acquisition spend
================================================================================
*/
