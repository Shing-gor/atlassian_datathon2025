# Atlassian Engagement & Retention — Synthetic Dataset
time series need

classification features: plan_tier company_size industry acquisition_channel is_enterprise expansion_event session_length_sec app_version latency_ms duration_ms success active_seats invoices_overdue discount_applied
### users.csv
| column | description | my notes |
|---|---|---|
| user_id | Unique user identifier |  |
| signup_date | Date when user signed up |  |
| plan_tier | User's subscription plan |  |
| company_size | Size category of user's company |
| region | Geographic region |
| industry | Business industry category |
| acquisition_channel | How user was acquired |
| is_enterprise | Whether user is enterprise customer |
| churned_30d | User churned within 30 days |
| churned_90d | User churned within 90 days |
| downgraded | User downgraded their plan |
| expansion_event | User expanded their usage |

### sessions.csv
| column | notes |
|---|---|
| session_id | Unique session identifier |
| user_id | User identifier |
| session_start / session_end | Session start and end timestamps |
| device | Device type used |
| os | Operating system |
| app_version | Application version |
| country | Country code |
| session_length_sec | Session duration in seconds |

### events.csv
| column | notes |
|---|---|
| event_id | Unique event identifier |
| user_id | User identifier |
| session_id | Session identifier |
| ts | Event timestamp |
| feature_name | Feature being used |
| action | Type of action performed |
| duration_ms | Event duration in milliseconds | use for how long
| latency_ms | Response latency in milliseconds | delay 
| success | Whether event completed successfully |

### billing.csv
| column | notes |
|---|---|
| user_id | User identifier | distinct |
| month | Billing month | 18 months |
| plan_tier | Current subscription plan | ['free' 'standard' 'premium'] |
| active_seats | Number of active seats | 0 - 700
| mrr | Monthly recurring revenue |
| discount_applied | Whether discount was applied | 0, 1
| invoices_overdue | Whether invoices are overdue | 0, 1, important
| support_ticket_count | Number of support tickets | how many help requested, A high number could indicate either a highly engaged user or a user who is having a lot of problems with the product.



y = upgrades, downgrades, 