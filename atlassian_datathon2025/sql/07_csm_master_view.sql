/*
================================================================================
  ANALYSIS 7 — CSM Master View (Tableau Data Source)
================================================================================
  Author  : GTM Analytics — Downstream Optimization Layer
  Purpose : Single, denormalised account view that serves as the Tableau data
            source. One row per account. Every KPI pre-computed. CSMs drag
            and drop — no SQL required on their end.
  Patterns: Full multi-CTE pipeline join, COALESCE null-safety throughout,
            all derived metrics in one place, csm_priority_action tag
  Output  : Drop this into Tableau as a Text File (CSV) or materialise as
            a table/view in your data warehouse (BigQuery, Redshift, Snowflake)
  Tableau : Connect to outputs/csm_master_view.csv OR schedule this as a
            nightly materialised view and point Tableau to the live table
================================================================================
*/

WITH

-- ── Billing KPIs per user ─────────────────────────────────────────────────
billing_agg AS (
    SELECT
        user_id,
        ROUND(AVG(mrr), 2)                             AS avg_mrr,
        ROUND(MAX(mrr), 2)                             AS peak_mrr,
        ROUND(SUM(mrr), 2)                             AS lifetime_mrr,
        SUM(invoices_overdue)                          AS overdue_invoices,
        SUM(support_ticket_count)                      AS support_tickets,
        ROUND(AVG(active_seats), 1)                    AS avg_seats,
        COUNT(DISTINCT month)                          AS billing_months
    FROM billing
    GROUP BY user_id
),

-- ── Session KPIs per user ─────────────────────────────────────────────────
session_agg AS (
    SELECT
        user_id,
        COUNT(*)                                       AS total_sessions,
        ROUND(AVG(session_length_sec) / 60.0, 1)      AS avg_session_min,
        COUNT(DISTINCT SUBSTR(session_start, 1, 7))    AS active_months,
        MAX(SUBSTR(session_start, 1, 10))              AS last_session_date
    FROM sessions
    GROUP BY user_id
),

-- ── Feature / event KPIs per user ─────────────────────────────────────────
event_agg AS (
    SELECT
        user_id,
        COUNT(DISTINCT feature_name)                   AS unique_features,
        COUNT(*)                                       AS total_events,
        ROUND(AVG(success) * 100, 1)                   AS event_success_rate,
        ROUND(AVG(latency_ms), 0)                      AS avg_latency_ms
    FROM events
    GROUP BY user_id
),

-- ── Month-over-month session decay (for early warning signal) ─────────────
monthly_sessions AS (
    SELECT
        user_id,
        SUBSTR(session_start, 1, 7)   AS month,
        COUNT(*)                      AS cnt
    FROM sessions
    GROUP BY user_id, SUBSTR(session_start, 1, 7)
),
latest_two_months AS (
    SELECT
        user_id,
        MAX(CASE WHEN rn = 1 THEN cnt END) AS latest_sessions,
        MAX(CASE WHEN rn = 2 THEN cnt END) AS prev_sessions
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY user_id
                ORDER BY month DESC
            ) AS rn
        FROM monthly_sessions
    ) sub
    WHERE rn <= 2
    GROUP BY user_id
)

-- ── Final master view ─────────────────────────────────────────────────────
SELECT

    /* ── Identity ─────────────────────────────────────────────────── */
    u.user_id,
    u.signup_date,
    u.plan_tier,
    u.company_size,
    u.region,
    u.industry,
    u.acquisition_channel,
    u.is_enterprise,

    /* ── Outcome flags ────────────────────────────────────────────── */
    u.churned_90d,
    u.churned_30d,
    u.expansion_event,
    u.downgraded,

    /* ── Billing KPIs ─────────────────────────────────────────────── */
    COALESCE(b.avg_mrr,          0)  AS avg_mrr,
    COALESCE(b.peak_mrr,         0)  AS peak_mrr,
    COALESCE(b.lifetime_mrr,     0)  AS lifetime_mrr,
    COALESCE(b.overdue_invoices, 0)  AS overdue_invoices,
    COALESCE(b.support_tickets,  0)  AS support_tickets,
    COALESCE(b.avg_seats,        0)  AS avg_seats,
    COALESCE(b.billing_months,   0)  AS billing_months,

    /* ── Session / engagement KPIs ────────────────────────────────── */
    COALESCE(s.total_sessions,     0)  AS total_sessions,
    COALESCE(s.avg_session_min,    0)  AS avg_session_min,
    COALESCE(s.active_months,      0)  AS active_months,
    s.last_session_date,

    /* ── Feature KPIs ─────────────────────────────────────────────── */
    COALESCE(e.unique_features,    0)  AS unique_features,
    COALESCE(e.total_events,       0)  AS total_events,
    COALESCE(e.event_success_rate, 0)  AS event_success_rate,
    COALESCE(e.avg_latency_ms,     0)  AS avg_latency_ms,

    /* ── Derived: session momentum ────────────────────────────────── */
    ROUND(
        CASE
            WHEN COALESCE(lt.prev_sessions, 0) > 0
            THEN (COALESCE(lt.latest_sessions, 0) - lt.prev_sessions) * 100.0
                 / lt.prev_sessions
            ELSE 0
        END,
    1)                               AS session_mom_pct,

    /* ── Derived: engagement decay signal ─────────────────────────── */
    CASE
        WHEN COALESCE(lt.latest_sessions, 0) = 0
             THEN 'Gone Dark'
        WHEN COALESCE(lt.latest_sessions, 0) < COALESCE(lt.prev_sessions,0) * 0.50
             THEN 'Rapid Decline'
        WHEN COALESCE(lt.latest_sessions, 0) < COALESCE(lt.prev_sessions,0) * 0.75
             THEN 'Mild Decline'
        ELSE 'Stable'
    END                              AS engagement_signal,

    /* ── Derived: composite health score (0–100) ──────────────────── */
    MIN(100, MAX(0,
        CASE WHEN COALESCE(s.active_months,0)>=9  THEN 25
             WHEN COALESCE(s.active_months,0)>=5  THEN 15
             WHEN COALESCE(s.active_months,0)>=2  THEN  8 ELSE 0 END
      + CASE WHEN COALESCE(e.unique_features,0)>=6 THEN 25
             WHEN COALESCE(e.unique_features,0)>=4 THEN 15
             WHEN COALESCE(e.unique_features,0)>=2 THEN  8 ELSE 0 END
      + CASE WHEN COALESCE(b.overdue_invoices,0)=0 THEN 15 ELSE 0 END
      + CASE WHEN COALESCE(b.support_tickets,0)=0  THEN 10
             WHEN COALESCE(b.support_tickets,0)<=2 THEN  5 ELSE 0 END
      + CASE WHEN COALESCE(b.avg_mrr,0)>=500       THEN 25
             WHEN COALESCE(b.avg_mrr,0)>=100       THEN 15
             WHEN COALESCE(b.avg_mrr,0)>0          THEN  5 ELSE 0 END
    ))                               AS health_score,

    /* ── Derived: CSM priority action (single-label for Tableau) ──── */
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

        WHEN COALESCE(lt.latest_sessions, 0) = 0
             AND u.churned_90d = 0
             THEN 'AT-RISK — Gone Dark'

        WHEN COALESCE(lt.latest_sessions, 0) < COALESCE(lt.prev_sessions,0) * 0.50
             AND u.churned_90d = 0
             THEN 'AT-RISK — Rapid Decline'

        ELSE 'MONITOR'
    END                              AS csm_priority_action

FROM users u
LEFT JOIN billing_agg       b  ON u.user_id = b.user_id
LEFT JOIN session_agg       s  ON u.user_id = s.user_id
LEFT JOIN event_agg         e  ON u.user_id = e.user_id
LEFT JOIN latest_two_months lt ON u.user_id = lt.user_id
ORDER BY
    CASE csm_priority_action
        WHEN 'AT-RISK — Gone Dark'          THEN 1
        WHEN 'AT-RISK — Rapid Decline'      THEN 2
        WHEN 'HOT — Free to Standard'       THEN 3
        WHEN 'HOT — Standard to Enterprise' THEN 4
        WHEN 'WARM — Nurture to Standard'   THEN 5
        WHEN 'WARM — Expand Seat Count'     THEN 6
        ELSE 7
    END,
    avg_mrr DESC;

/*
================================================================================
  TABLEAU SETUP GUIDE
  -------------------
  1. Run this query and export to CSV (or materialise as a DB view)
  2. In Tableau Desktop: Data → New Data Source → Text File
  3. Recommended Tableau Views:
     ─────────────────────────────────────────────────────────
     View A: CSM Priority Queue
       Rows: user_id, plan_tier, avg_mrr, health_score
       Filter: csm_priority_action = 'HOT...' or 'AT-RISK...'
       Sort: avg_mrr DESC

     View B: Health Score Distribution
       Chart: Histogram of health_score
       Colour: health_segment (AT-RISK / MODERATE / HEALTHY)
       Reference lines at 40 and 70

     View C: MRR at Risk by Signal
       Chart: Bar chart of SUM(avg_mrr) by engagement_signal
       Colour: Red / Orange / Yellow / Green

     View D: Upsell Pipeline Funnel
       Chart: Treemap or bar chart of COUNT by csm_priority_action
       Size: SUM(monthly_revenue_upside)
================================================================================
*/
