-- =====================================================================
-- 04_data_quality_checks.sql
-- Each check returns how many rows fail it. Checks on RAW show what problems
-- arrived; checks on CORE must all be 0, otherwise cleaning missed something.
-- The pipeline prints this table after every run and fails if a core check fails.
-- =====================================================================

WITH checks AS (
    -- ---------- RAW layer: what came in ----------
    SELECT 'raw' AS layer, 'Exact duplicate submission rows' AS check_name, 'info' AS severity,
           (SELECT COUNT(*) - COUNT(DISTINCT submission_id) FROM raw.form_submissions) AS failed_rows
    UNION ALL
    SELECT 'raw', 'Submissions from unknown employees', 'info',
           (SELECT COUNT(*) FROM raw.form_submissions s
             WHERE NOT EXISTS (SELECT 1 FROM raw.employees e WHERE e.employee_id = s.employee_id))
    UNION ALL
    SELECT 'raw', 'Submissions with future timestamps', 'info',
           (SELECT COUNT(*) FROM raw.form_submissions WHERE submitted_at > now())
    UNION ALL
    SELECT 'raw', 'Non-standard status values', 'info',
           (SELECT COUNT(*) FROM raw.form_submissions WHERE status <> 'completed')
    UNION ALL
    SELECT 'raw', 'Submissions with missing score', 'info',
           (SELECT COUNT(*) FROM raw.form_submissions WHERE score IS NULL)

    -- ---------- CORE layer: must be clean ----------
    UNION ALL
    SELECT 'core', 'Duplicate submissions per form, subject and local day', 'error',
           (SELECT COUNT(*) FROM (
                SELECT s.form_id,
                       CASE WHEN f.form_level = 'store' THEN s.store_id ELSE s.employee_id END,
                       s.local_date
                FROM core.form_submissions s JOIN core.forms f USING (form_id)
                GROUP BY 1, 2, 3 HAVING COUNT(*) > 1) d)
    UNION ALL
    SELECT 'core', 'Submissions with future timestamps', 'error',
           (SELECT COUNT(*) FROM core.form_submissions WHERE submitted_at > now())
    UNION ALL
    SELECT 'core', 'Non-standard status values', 'error',
           (SELECT COUNT(*) FROM core.form_submissions WHERE status NOT IN ('completed', 'partial'))
    UNION ALL
    SELECT 'core', 'Submission tenant differs from its form''s tenant', 'error',
           (SELECT COUNT(*) FROM core.form_submissions s JOIN core.forms f USING (form_id)
             WHERE f.tenant_id <> s.tenant_id)
    UNION ALL
    SELECT 'core', 'Raw rows not accounted for (core + rejected <> raw)', 'error',
           (SELECT ABS((SELECT COUNT(*) FROM raw.form_submissions)
                     - (SELECT COUNT(*) FROM core.form_submissions)
                     - (SELECT COUNT(*) FROM core.rejected_submissions WHERE reprocessed_at IS NULL)))
    UNION ALL
    SELECT 'core', 'Odd-hour submissions (00:00-05:00 local), review', 'warning',
           (SELECT COUNT(*) FROM core.form_submissions WHERE is_odd_hour)
    UNION ALL
    SELECT 'core', 'Course completed before it was started', 'error',
           (SELECT COUNT(*) FROM core.course_progress WHERE completed_on < started_on)
)
SELECT layer, check_name, severity, failed_rows,
       CASE WHEN failed_rows = 0 THEN 'PASS'
            WHEN severity = 'error' THEN 'FAIL'
            ELSE 'FLAG' END AS result
FROM checks
ORDER BY layer DESC, check_name;
