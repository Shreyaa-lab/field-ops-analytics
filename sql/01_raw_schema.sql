-- =====================================================================
-- 01_raw_schema.sql
-- Raw landing layer: data is loaded exactly as it arrives from the CSVs.
-- No primary keys or foreign keys here on purpose, so bad rows (duplicates,
-- orphans) can land and be inspected instead of failing the whole load.
-- =====================================================================

DROP SCHEMA IF EXISTS raw CASCADE;
CREATE SCHEMA raw;

CREATE TABLE raw.tenants (
    tenant_id     INT,
    tenant_name   TEXT,
    industry      TEXT,
    timezone      TEXT,
    onboarded_on  DATE
);

CREATE TABLE raw.stores (
    store_id    INT,
    tenant_id   INT,
    store_name  TEXT,
    city        TEXT,
    region      TEXT,
    opened_on   DATE
);

CREATE TABLE raw.employees (
    employee_id  INT,
    tenant_id    INT,
    store_id     INT,
    full_name    TEXT,
    role         TEXT,
    phone        TEXT,
    joined_on    DATE,
    left_on      DATE
);

CREATE TABLE raw.forms (
    form_id         INT,
    tenant_id       INT,
    form_name       TEXT,
    form_level      TEXT,     -- 'store' or 'employee'
    due_local_time  TIME,
    frequency       TEXT
);

CREATE TABLE raw.courses (
    course_id       INT,
    tenant_id       INT,
    course_name     TEXT,
    total_chapters  INT
);

CREATE TABLE raw.course_progress (
    employee_id         INT,
    course_id           INT,
    tenant_id           INT,
    assigned_on         DATE,
    started_on          DATE,
    completed_on        DATE,
    chapters_completed  INT
);

CREATE TABLE raw.form_submissions (
    submission_id  BIGINT,
    tenant_id      INT,
    form_id        INT,
    employee_id    INT,
    store_id       INT,
    submitted_at   TIMESTAMPTZ,  -- stored in UTC
    status         TEXT,         -- messy on purpose: 'Completed', ' completed ', 'COMPLETE'
    score          NUMERIC(5,1),
    channel        TEXT
);

CREATE TABLE raw.reminders (
    reminder_id    BIGINT,
    tenant_id      INT,
    form_id        INT,
    employee_id    INT,
    store_id       INT,
    sent_at        TIMESTAMPTZ,
    reminder_type  TEXT,         -- 'reminder' (before due) or 'escalation' (after a miss)
    delivered      BOOLEAN
);
