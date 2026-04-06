/*
================================================================================
  ANALYSIS 2 — Account Health Scoring Engine
================================================================================
  Author  : GTM Analytics — Downstream Optimization Layer
  Purpose : Compute a single 0–100 composite health score per account,
            combining engagement depth, feature breadth, billing health,
            support load, and revenue signal.
  Patterns: Multi-table LEFT JOIN, CASE-weighted scoring, COALESCE null-safety,
            NULLIF division guard, nested CTEs
  Output  : One row per user with all KPIs and final health_score
  Tableau : Filter health_score < 40 for the AT-RISK account view
================================================================================

  HEALTH SCORE FORMULA (0–100)
  ┌──────────────────────────────────────────────┬──────────┐
  │ Dimension                                    │ Max Pts  │
  ├──────────────────────────────────────────────┼──────────┤
  │ 1. Engagement Depth  (active billing months) │   25     │
  │ 2. Feature Breadth   (unique features used)  │   25     │
  │ 3. Billing Health    (zero overdue invoices) │   15     │
  │ 4. Support Load      (low ticket count)      │   10     │
  │ 5. Revenue Signal    (average MRR)           │   25     │
  └──────────────────────────────────────────────┴──────────┘
*/

WITH session_agg AS (
    SELECT
        user_id,
        COUNT(*)                                        AS session_count,
        ROUND(AVG(session_length_sec), 1)               AS avg_session_sec,
        COUNT(DISTINCT SUBSTR(session_start, 1, 7))     AS active_months
    FROM sessions
    GROUP BY user_id
),

event_agg AS (
    SELECT
        user_id,
        COUNT(DISTINCT feature_name)                    AS unique_features,
        COUNT(*)                                        AS total_events,
        ROUND(AVG(success) * 100, 1)                   AS event_success_rate,
        ROUND(AVG(latency_ms), 0)                       AS avg_latency_ms
    FROM events
    GROUP BY user_id
),

billing_agg AS (
    SELECT
        user_id,
        ROUND(AVG(mrr), 2)                             AS avg_mrr,
        ROUND(MAX(mrr), 2)                             AS peak_mrr,
        SUM(invoices_overdue)                          AS overdue_invoices,
        SUM(support_ticket_count)                      AS support_tickets,
        ROUND(AVG(active_seats), 1)                    AS avg_seats
    FROM billing
    GROUP BY user_id
)

SELECT
    u.user_id,
    u.plan_tier,
    u.company_size,
    u.region,
    u.industry,
    u.acquisition_channel,
    u.is_enterprise,
    u.churned_90d,
    u.expansion_event,

    -- ── Engagement KPIs ──────────────────────────────────────────────
    COALESCE(s.session_count,      0)                  AS session_count,
    COALESCE(s.active_months,      0)                  AS active_months,
    COALESCE(e.unique_features,    0)                  AS unique_features,
    COALESCE(e.total_events,       0)                  AS total_events,
    COALESCE(e.event_success_rate, 0)                  AS event_success_rate,

    -- ── Billing KPIs ─────────────────────────────────────────────────
    COALESCE(b.avg_mrr,            0)                  AS avg_mrr,
    COALESCE(b.peak_mrr,           0)                  AS peak_mrr,
    COALESCE(b.overdue_invoices,   0)                  AS overdue_invoices,
    COALESCE(b.support_tickets,    0)                  AS support_tickets,
    COALESCE(b.avg_seats,          0)                  AS avg_seats,

    -- ── Composite Health Score (0–100) ────────────────────────────────
    MIN(100, MAX(0,

        /* 1. Engagement Depth: how long has the user been consistently active? */
        CASE WHEN COALESCE(s.active_months, 0) >= 9 THEN 25
             WHEN COALESCE(s.active_months, 0) >= 5 THEN 15
             WHEN COALESCE(s.active_months, 0) >= 2 THEN  8
             ELSE 0 END

        /* 2. Feature Breadth: how deeply embedded in the platform? */
      + CASE WHEN COALESCE(e.unique_features, 0) >= 6 THEN 25
             WHEN COALESCE(e.unique_features, 0) >= 4 THEN 15
             WHEN COALESCE(e.unique_features, 0) >= 2 THEN  8
             ELSE 0 END

        /* 3. Billing Health: are invoices current? */
      + CASE WHEN COALESCE(b.overdue_invoices, 0) = 0 THEN 15 ELSE 0 END

        /* 4. Support Load: high ticket volume signals dissatisfaction */
      + CASE WHEN COALESCE(b.support_tickets,  0) = 0 THEN 10
             WHEN COALESCE(b.support_tickets,  0) <= 2 THEN  5
             ELSE 0 END

        /* 5. Revenue Signal: is this a monetised account? */
      + CASE WHEN COALESCE(b.avg_mrr, 0) >= 500 THEN 25
             WHEN COALESCE(b.avg_mrr, 0) >= 100 THEN 15
             WHEN COALESCE(b.avg_mrr, 0) >   0  THEN  5
             ELSE 0 END

    ))                                                 AS health_score,

    -- ── Segmentation Label (for Tableau filter) ───────────────────────
    CASE
        WHEN MIN(100, MAX(0,
            CASE WHEN COALESCE(s.active_months,0)>=9 THEN 25
                 WHEN COALESCE(s.active_months,0)>=5 THEN 15
                 WHEN COALESCE(s.active_months,0)>=2 THEN  8 ELSE 0 END
          + CASE WHEN COALESCE(e.unique_features,0)>=6 THEN 25
                 WHEN COALESCE(e.unique_features,0)>=4 THEN 15
                 WHEN COALESCE(e.unique_features,0)>=2 THEN  8 ELSE 0 END
          + CASE WHEN COALESCE(b.overdue_invoices,0)=0 THEN 15 ELSE 0 END
          + CASE WHEN COALESCE(b.support_tickets,0)=0  THEN 10
                 WHEN COALESCE(b.support_tickets,0)<=2 THEN  5 ELSE 0 END
          + CASE WHEN COALESCE(b.avg_mrr,0)>=500 THEN 25
                 WHEN COALESCE(b.avg_mrr,0)>=100 THEN 15
                 WHEN COALESCE(b.avg_mrr,0)>0    THEN  5 ELSE 0 END
        )) < 40  THEN 'AT-RISK'
        WHEN MIN(100, MAX(0,
            CASE WHEN COALESCE(s.active_months,0)>=9 THEN 25
                 WHEN COALESCE(s.active_months,0)>=5 THEN 15
                 WHEN COALESCE(s.active_months,0)>=2 THEN  8 ELSE 0 END
          + CASE WHEN COALESCE(e.unique_features,0)>=6 THEN 25
                 WHEN COALESCE(e.unique_features,0)>=4 THEN 15
                 WHEN COALESCE(e.unique_features,0)>=2 THEN  8 ELSE 0 END
          + CASE WHEN COALESCE(b.overdue_invoices,0)=0 THEN 15 ELSE 0 END
          + CASE WHEN COALESCE(b.support_tickets,0)=0  THEN 10
                 WHEN COALESCE(b.support_tickets,0)<=2 THEN  5 ELSE 0 END
          + CASE WHEN COALESCE(b.avg_mrr,0)>=500 THEN 25
                 WHEN COALESCE(b.avg_mrr,0)>=100 THEN 15
                 WHEN COALESCE(b.avg_mrr,0)>0    THEN  5 ELSE 0 END
        )) >= 70 THEN 'HEALTHY'
        ELSE 'MODERATE'
    END                                                AS health_segment

FROM users u
LEFT JOIN session_agg s ON u.user_id = s.user_id
LEFT JOIN event_agg   e ON u.user_id = e.user_id
LEFT JOIN billing_agg b ON u.user_id = b.user_id
ORDER BY health_score DESC;

/*
================================================================================
  CSM INSIGHT
  -----------
  • health_score < 40  → AT-RISK: prioritise proactive outreach queue
  • health_score 40–69 → MODERATE: monitor + targeted campaigns
  • health_score ≥ 70  → HEALTHY: expansion conversation candidates
  • Revenue at risk = SUM(avg_mrr) WHERE health_score < 40
================================================================================
*/
