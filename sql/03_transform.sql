-- =====================================================================
-- 03_transform.sql
-- Raw -> core. A full refresh: core tables are rebuilt from raw each run,
-- which keeps the pipeline idempotent (running it twice gives the same result).
--
-- Cleaning rules for submissions, applied in this order:
--   1. exact_duplicate       same submission_id loaded more than once
--   2. unknown_employee      employee_id not found in employees (orphan)
--   3. future_timestamp      submitted_at later than load time (device clock skew)
--   4. duplicate_submission  a second submission for the same form + subject
--                            (store or employee) on the same LOCAL day; keep the earliest
-- Status text is standardised: lower(trim()), and 'complete' -> 'completed'.
-- =====================================================================

-- Dimensions: straight copy with types enforced by core constraints
INSERT INTO core.tenants  SELECT DISTINCT * FROM raw.tenants;
INSERT INTO core.stores   SELECT DISTINCT * FROM raw.stores;
INSERT INTO core.employees SELECT DISTINCT * FROM raw.employees;
INSERT INTO core.forms    SELECT DISTINCT * FROM raw.forms;
INSERT INTO core.courses  SELECT DISTINCT * FROM raw.courses;
INSERT INTO core.course_progress SELECT DISTINCT * FROM raw.course_progress;

-- Stage submissions with everything needed to decide keep vs reject
DROP TABLE IF EXISTS pg_temp.stg_submissions;
CREATE TEMP TABLE stg_submissions AS
WITH base AS (
    SELECT
        r.*,
        t.timezone,
        f.form_level,
        f.due_local_time,
        (r.submitted_at AT TIME ZONE t.timezone)                       AS local_ts,
        (e.employee_id IS NOT NULL)                                     AS employee_exists,
        ROW_NUMBER() OVER (PARTITION BY r.submission_id ORDER BY r.ctid) AS id_copy
    FROM raw.form_submissions r
    JOIN core.tenants t ON t.tenant_id = r.tenant_id
    JOIN core.forms   f ON f.form_id   = r.form_id
    LEFT JOIN core.employees e ON e.employee_id = r.employee_id
),
flagged AS (
    SELECT
        b.*,
        CASE
            WHEN id_copy > 1            THEN 'exact_duplicate'
            WHEN NOT employee_exists    THEN 'unknown_employee'
            WHEN submitted_at > now()   THEN 'future_timestamp'
        END AS hard_reject
    FROM base b
)
SELECT
    f.*,
    CASE
        WHEN hard_reject IS NOT NULL THEN hard_reject
        WHEN ROW_NUMBER() OVER (
                 PARTITION BY tenant_id, form_id,
                              CASE WHEN form_level = 'store' THEN store_id ELSE employee_id END,
                              local_ts::date,
                              (hard_reject IS NULL)
                 ORDER BY submitted_at, submission_id) > 1
             THEN 'duplicate_submission'
    END AS rejection_reason
FROM flagged f;

-- Good rows -> core
INSERT INTO core.form_submissions
SELECT
    submission_id, tenant_id, form_id, employee_id, store_id,
    submitted_at,
    local_ts,
    local_ts::date,
    CASE WHEN lower(trim(status)) IN ('complete', 'completed') THEN 'completed'
         ELSE lower(trim(status)) END,
    score,
    lower(trim(channel)),
    local_ts::time <= due_local_time,
    EXTRACT(HOUR FROM local_ts) < 5
FROM stg_submissions
WHERE rejection_reason IS NULL;

-- Bad rows -> quarantine, with the reason
INSERT INTO core.rejected_submissions
    (submission_id, tenant_id, form_id, employee_id, store_id,
     submitted_at, status, score, channel, rejection_reason)
SELECT submission_id, tenant_id, form_id, employee_id, store_id,
       submitted_at, status, score, channel, rejection_reason
FROM stg_submissions
WHERE rejection_reason IS NOT NULL;

-- Reminders: dedupe on id and compute the tenant-local date
INSERT INTO core.reminders
SELECT DISTINCT ON (r.reminder_id)
    r.reminder_id, r.tenant_id, r.form_id, r.employee_id, r.store_id,
    r.sent_at,
    (r.sent_at AT TIME ZONE t.timezone)::date,
    lower(trim(r.reminder_type)),
    COALESCE(r.delivered, FALSE)
FROM raw.reminders r
JOIN core.tenants t ON t.tenant_id = r.tenant_id
JOIN core.employees e ON e.employee_id = r.employee_id
ORDER BY r.reminder_id;

ANALYZE core.form_submissions;
ANALYZE core.reminders;
