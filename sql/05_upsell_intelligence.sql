/*
================================================================================
  ANALYSIS 5 — Upsell Intelligence Engine
================================================================================
  Author  : GTM Analytics — Downstream Optimization Layer
  Purpose : Score every currently-active account against upgrade-readiness
            criteria. Surface the expansion pipeline with estimated ARR upside.
  Patterns: Multi-CTE scoring pipeline, business-rule CASE logic,
            NULLIF division guard, GROUP BY rollup for pipeline summary
  Output  : Summary table (csm_action × pipeline metrics)
            Full account-level table available in csm_master_view.sql
  Tableau : Funnel chart by csm_action; drill to individual accounts
================================================================================

  UPSELL TIER LOGIC
  ┌──────────────────────────────────┬────────────────────────────────────────┐
  │ Tag                              │ Criteria                               │
  ├──────────────────────────────────┼────────────────────────────────────────┤
  │ HOT — Free to Standard           │ free + ≥4 active months + ≥3 features  │
  │                                  │ + zero overdue invoices                │
  │ HOT — Standard to Enterprise     │ standard + ≥25 avg seats               │
  │                                  │ + ≥8 active months + zero overdue      │
  │ WARM — Nurture to Standard       │ free + ≥2 active months + ≥2 features  │
  │ WARM — Expand Seat Count         │ standard + ≥15 avg seats               │
  └──────────────────────────────────┴────────────────────────────────────────┘
*/

WITH billing_agg AS (
    SELECT
        user_id,
        ROUND(AVG(mrr), 2)              AS avg_mrr,
        ROUND(MAX(mrr), 2)              AS peak_mrr,
        SUM(invoices_overdue)           AS overdue_invoices,
        SUM(support_ticket_count)       AS support_tickets,
        ROUND(AVG(active_seats), 1)     AS avg_seats,
        COUNT(DISTINCT month)           AS billing_months
    FROM billing
    GROUP BY user_id
),

session_agg AS (
    SELECT
        user_id,
        COUNT(*)                                        AS session_count,
        COUNT(DISTINCT SUBSTR(session_start, 1, 7))     AS active_months
    FROM sessions
    GROUP BY user_id
),

event_agg AS (
    SELECT
        user_id,
        COUNT(DISTINCT feature_name)                    AS unique_features
    FROM events
    GROUP BY user_id
),

-- Score each account
scored_accounts AS (
    SELECT
        u.user_id,
        u.plan_tier,
        u.company_size,
        u.region,
        u.industry,
        u.acquisition_channel,
        COALESCE(b.avg_mrr,          0)  AS avg_mrr,
        COALESCE(b.avg_seats,        0)  AS avg_seats,
        COALESCE(b.overdue_invoices, 0)  AS overdue_invoices,
        COALESCE(b.support_tickets,  0)  AS support_tickets,
        COALESCE(s.session_count,    0)  AS session_count,
        COALESCE(s.active_months,    0)  AS active_months,
        COALESCE(e.unique_features,  0)  AS unique_features,
        u.churned_90d,
        u.expansion_event,

        -- ── Upsell Action Tag ────────────────────────────────────────
        CASE
            WHEN u.plan_tier = 'free'
                 AND COALESCE(s.active_months,    0) >= 4
                 AND COALESCE(e.unique_features,  0) >= 3
                 AND COALESCE(b.overdue_invoices, 0) =  0
                 THEN 'HOT — Free to Standard'

            WHEN u.plan_tier = 'standard'
                 AND COALESCE(b.avg_seats,        0) >= 25
                 AND COALESCE(s.active_months,    0) >= 8
                 AND COALESCE(b.overdue_invoices, 0) =  0
                 THEN 'HOT — Standard to Enterprise'

            WHEN u.plan_tier = 'free'
                 AND COALESCE(s.active_months,    0) >= 2
                 AND COALESCE(e.unique_features,  0) >= 2
                 THEN 'WARM — Nurture to Standard'

            WHEN u.plan_tier = 'standard'
                 AND COALESCE(b.avg_seats,        0) >= 15
                 THEN 'WARM — Expand Seat Count'

            ELSE 'MONITOR'
        END                              AS csm_action,

        -- ── Monthly Revenue Upside (conservative estimates) ──────────
        CASE
            WHEN u.plan_tier = 'free'                          THEN 108
            WHEN u.plan_tier = 'standard'
                 AND COALESCE(b.avg_seats, 0) >= 25            THEN 900
            WHEN u.plan_tier = 'standard'                      THEN 200
            ELSE 0
        END                              AS monthly_revenue_upside

    FROM users u
    LEFT JOIN billing_agg b ON u.user_id = b.user_id
    LEFT JOIN session_agg s ON u.user_id = s.user_id
    LEFT JOIN event_agg   e ON u.user_id = e.user_id
    WHERE u.churned_90d = 0             -- only score active accounts
)

-- ── Pipeline Summary (for executive view) ──────────────────────────────────
SELECT
    csm_action,
    COUNT(*)                                         AS account_count,
    ROUND(AVG(avg_mrr), 2)                           AS avg_current_mrr,
    SUM(monthly_revenue_upside)                      AS total_monthly_upside,
    ROUND(SUM(monthly_revenue_upside) * 12, 0)       AS annualised_pipeline_usd,
    ROUND(AVG(active_months), 1)                     AS avg_active_months,
    ROUND(AVG(unique_features), 1)                   AS avg_features_used,
    ROUND(AVG(avg_seats), 1)                         AS avg_current_seats,
    ROUND(AVG(support_tickets), 1)                   AS avg_support_tickets
FROM scored_accounts
WHERE csm_action != 'MONITOR'
GROUP BY csm_action
ORDER BY total_monthly_upside DESC;

-- ── To get individual account-level list, uncomment below ──────────────────
-- SELECT * FROM scored_accounts WHERE csm_action != 'MONITOR'
-- ORDER BY csm_action, monthly_revenue_upside DESC;

/*
================================================================================
  CSM INSIGHT
  -----------
  • HOT leads: direct CSM outreach within 5 business days
  • Reference Feature Correlation (Analysis 4) for personalised pitch hooks
  • WARM leads: automated email nurture sequence (feature discovery content)
  • Pipeline conversion assumption: HOT = 35% close rate | WARM = 15% close rate
  • Adjusted ARR estimate = annualised_pipeline × conversion_rate
================================================================================
*/
