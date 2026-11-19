-- =====================================================================
-- benchmark_queries.sql
-- Query patterns used by dashboards and support troubleshooting.
-- src/benchmark.py runs each one with and without the indexes in
-- 06_indexes.sql and reports the difference.
-- Parameters (%(name)s) are filled in by the script.
-- =====================================================================

-- name: Store manager view - one store, last 14 days
SELECT local_date, form_id, COUNT(*) AS submissions, ROUND(AVG(score), 1) AS avg_score
FROM core.form_submissions
WHERE store_id = %(store_id)s
  AND local_date >= %(day_minus_14)s
GROUP BY local_date, form_id
ORDER BY local_date;

-- name: Support troubleshooting - one employee's latest submissions
SELECT submission_id, form_id, submitted_local_ts, status, is_on_time
FROM core.form_submissions
WHERE employee_id = %(employee_id)s
ORDER BY submitted_at DESC
LIMIT 20;

-- name: Tenant dashboard - daily volume for the last 7 days
SELECT local_date, COUNT(*) AS submissions,
       COUNT(*) FILTER (WHERE is_on_time) AS on_time
FROM core.form_submissions
WHERE tenant_id = %(tenant_id)s
  AND local_date BETWEEN %(day_minus_7)s AND %(last_day)s
GROUP BY local_date
ORDER BY local_date;

-- name: Reminder follow-up - one tenant, one week
SELECT r.reminder_id, s.submission_id,
       EXTRACT(EPOCH FROM (s.submitted_at - r.sent_at)) / 60 AS minutes_to_submit
FROM core.reminders r
LEFT JOIN core.form_submissions s
       ON s.form_id = r.form_id
      AND s.local_date = r.local_date
      AND s.employee_id = r.employee_id
      AND s.submitted_at >= r.sent_at
WHERE r.tenant_id = %(tenant_id)s
  AND r.local_date BETWEEN %(day_minus_7)s AND %(last_day)s
  AND r.reminder_type = 'reminder';
