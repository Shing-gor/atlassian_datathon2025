# SQL Library — Downstream Optimization Analysis

> Standalone SQL files designed to run against the Atlassian engagement dataset.
> Compatible with **DuckDB**, **PostgreSQL**, **BigQuery**, **Snowflake**, and **SQLite 3.25+**.
> Each file is self-contained with full inline documentation and CSM insight commentary.

---

## File Index

| File | Analysis | Key SQL Patterns |
|---|---|---|
| `01_mrr_waterfall.sql` | MRR Trend by Plan Tier | `LAG()`, `PARTITION BY`, `COALESCE` |
| `02_account_health_score.sql` | Composite Account Health (0–100) | Multi-table `JOIN`, `CASE` scoring, `MIN/MAX` clamp |
| `03_churn_early_warning.sql` | Engagement Decay Signals | `ROW_NUMBER()`, conditional aggregation |
| `04_feature_revenue_correlation.sql` | Feature → Expansion Correlation | Two-level aggregation, `HAVING`, derived scores |
| `05_upsell_intelligence.sql` | Upsell Pipeline Sizing | Multi-CTE pipeline, business-rule `CASE`, `GROUP BY` rollup |
| `06_acquisition_channel_roi.sql` | Channel × Industry LTV Ranking | `RANK()` window, risk-adjusted LTV, `HAVING` |
| `07_csm_master_view.sql` | Tableau Master Data Source | Full pipeline join, all KPIs in one view |

---

## Quick Start

```sql
-- Run in DuckDB (fastest for local CSV files)
-- Replace path with your data directory

CREATE VIEW billing  AS SELECT * FROM read_csv_auto('data/billing.csv');
CREATE VIEW users    AS SELECT * FROM read_csv_auto('data/users.csv');
CREATE VIEW sessions AS SELECT * FROM read_csv_auto('data/sessions.csv');
CREATE VIEW events   AS SELECT * FROM read_csv_auto('data/events.csv');

-- Then run any analysis file directly:
-- .read sql/07_csm_master_view.sql
```

```python
# Or via Python + SQLite (no additional dependencies)
import sqlite3, pandas as pd

conn = sqlite3.connect(':memory:')
for table in ['billing','users','sessions','events']:
    pd.read_csv(f'data/{table}.csv').to_sql(table, conn, index=False)

with open('sql/07_csm_master_view.sql') as f:
    query = f.read().split('/*')[0]   # strip comments if needed

master = pd.read_sql_query(query, conn)
master.to_csv('outputs/csm_master_view.csv', index=False)
```

---

## Tableau Connection

1. Run `07_csm_master_view.sql` and export to `outputs/csm_master_view.csv`
2. Tableau Desktop → **Data** → **New Data Source** → **Text File**
3. Recommended starter views:

| Tableau View | Dimensions | Measures | Filters |
|---|---|---|---|
| CSM Priority Queue | csm_priority_action, plan_tier | avg_mrr, health_score | ≠ MONITOR |
| Revenue at Risk | engagement_signal | SUM(avg_mrr) | churned_90d = 0 |
| Upsell Pipeline | csm_priority_action | COUNT, SUM(upside) | HOT or WARM only |
| Channel ROI | acquisition_channel, industry | risk_adj_ltv | cohort_size ≥ 30 |

---

*Part of the Atlassian × DataSoc Datathon 2025 — Customer Intelligence Platform*
