# Query benchmark results

Run on 2026-11-19 16:48 against 180,234 rows in `core.form_submissions`. Median of 15 runs of `EXPLAIN ANALYZE`, after one warm-up run.

| Query | Before (ms) | After (ms) | Improvement | Scan before | Scan after |
|---|---:|---:|---:|---|---|
| Store manager view - one store, last 14 days | 3.94 | 0.03 | 141x (99.3% less time) | Seq Scan | Index Scan |
| Support troubleshooting - one employee's latest submissions | 3.61 | 0.01 | 516x (99.8% less time) | Seq Scan | Index Scan |
| Tenant dashboard - daily volume for the last 7 days | 3.61 | 0.25 | 14x (93.0% less time) | Seq Scan | Index Scan |
| Reminder follow-up - one tenant, one week | 25.51 | 2.63 | 10x (89.7% less time) | Seq Scan | Bitmap Heap Scan, Bitmap Index Scan |
