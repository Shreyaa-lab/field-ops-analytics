-- =====================================================================
-- 07_reprocess_rejected.sql
-- Reprocessing: some submissions were rejected as 'unknown_employee' because
-- the employee's HR record arrived after their first submissions (a common
-- real-world timing problem). Once the late records are loaded into
-- core.employees, this script moves the now-valid rows from quarantine into
-- core, without rerunning the whole pipeline.
--
-- Safe to run repeatedly: rows already reprocessed are skipped, and a row is
-- not inserted if the same form + subject already has a submission that day.
-- =====================================================================

WITH candidates AS (
    SELECT r.*, t.timezone, f.form_level, f.due_local_time,
           (r.submitted_at AT TIME ZONE t.timezone) AS local_ts
    FROM core.rejected_submissions r
    JOIN core.employees e ON e.employee_id = r.employee_id      -- employee now exists
    JOIN core.tenants   t ON t.tenant_id   = r.tenant_id
    JOIN core.forms     f ON f.form_id     = r.form_id
    WHERE r.rejection_reason = 'unknown_employee'
      AND r.reprocessed_at IS NULL
      AND r.submitted_at <= now()   -- re-apply EVERY rule, not just the one that failed first
),
ranked AS (
    SELECT c.*,
           ROW_NUMBER() OVER (
               PARTITION BY form_id,
                            CASE WHEN form_level = 'store' THEN store_id ELSE employee_id END,
                            local_ts::date
               ORDER BY submitted_at, submission_id) AS rn
    FROM candidates c
),
inserted AS (
    INSERT INTO core.form_submissions
    SELECT submission_id, tenant_id, form_id, employee_id, store_id,
           submitted_at, local_ts, local_ts::date,
           CASE WHEN lower(trim(status)) IN ('complete', 'completed') THEN 'completed'
                ELSE lower(trim(status)) END,
           score, lower(trim(channel)),
           local_ts::time <= due_local_time,
           EXTRACT(HOUR FROM local_ts) < 5
    FROM ranked k
    WHERE rn = 1
      AND NOT EXISTS (
          SELECT 1 FROM core.form_submissions s
          WHERE s.form_id = k.form_id
            AND s.local_date = k.local_ts::date
            AND CASE WHEN k.form_level = 'store' THEN s.store_id = k.store_id
                     ELSE s.employee_id = k.employee_id END)
    RETURNING submission_id
)
UPDATE core.rejected_submissions r
SET reprocessed_at = now()
FROM inserted i
WHERE r.submission_id = i.submission_id
  AND r.rejection_reason = 'unknown_employee';

-- Rows whose employee now exists but that failed another rule: relabel them
-- with the real reason so the quarantine stays accurate.
UPDATE core.rejected_submissions r
SET rejection_reason = 'future_timestamp'
WHERE r.rejection_reason = 'unknown_employee'
  AND r.reprocessed_at IS NULL
  AND r.submitted_at > now()
  AND EXISTS (SELECT 1 FROM core.employees e WHERE e.employee_id = r.employee_id);

UPDATE core.rejected_submissions r
SET rejection_reason = 'duplicate_submission'
WHERE r.rejection_reason = 'unknown_employee'
  AND r.reprocessed_at IS NULL
  AND EXISTS (SELECT 1 FROM core.employees e WHERE e.employee_id = r.employee_id);

REFRESH MATERIALIZED VIEW analytics.fact_expected_vs_actual;
