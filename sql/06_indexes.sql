-- =====================================================================
-- 06_indexes.sql
-- Indexes chosen from the query patterns the dashboards and troubleshooting
-- queries actually use (see sql/benchmark_queries.sql). Column order matters:
-- the equality column first (tenant/store/employee), then the range column (date).
-- Run src/benchmark.py to measure the before/after difference.
-- =====================================================================

-- "All submissions for one tenant between two dates" (dashboards)
CREATE INDEX IF NOT EXISTS ix_sub_tenant_date
    ON core.form_submissions (tenant_id, local_date);

-- "Last 14 days for one store" (store manager view)
CREATE INDEX IF NOT EXISTS ix_sub_store_date
    ON core.form_submissions (store_id, local_date);

-- "Recent history of one employee" (support troubleshooting)
CREATE INDEX IF NOT EXISTS ix_sub_employee_submitted
    ON core.form_submissions (employee_id, submitted_at DESC);

-- Reminder -> submission matching (same form, same local day)
CREATE INDEX IF NOT EXISTS ix_sub_form_date
    ON core.form_submissions (form_id, local_date);

CREATE INDEX IF NOT EXISTS ix_rem_tenant_date
    ON core.reminders (tenant_id, local_date);

-- Foreign-key columns used in joins
CREATE INDEX IF NOT EXISTS ix_emp_store ON core.employees (store_id);
CREATE INDEX IF NOT EXISTS ix_progress_course ON core.course_progress (course_id);

ANALYZE core.form_submissions;
ANALYZE core.reminders;
