-- =====================================================================
-- 02_core_schema.sql
-- Core layer: cleaned, typed and constrained tables that analytics reads from.
-- Rejected rows go to core.rejected_submissions with a reason, so they can be
-- fixed and reprocessed later (see sql/07_reprocess_rejected.sql).
-- =====================================================================

DROP SCHEMA IF EXISTS analytics CASCADE;
DROP SCHEMA IF EXISTS core CASCADE;
CREATE SCHEMA core;

CREATE TABLE core.tenants (
    tenant_id     INT PRIMARY KEY,
    tenant_name   TEXT NOT NULL,
    industry      TEXT,
    timezone      TEXT NOT NULL,           -- IANA name, e.g. 'Asia/Kolkata'
    onboarded_on  DATE
);

CREATE TABLE core.stores (
    store_id    INT PRIMARY KEY,
    tenant_id   INT NOT NULL REFERENCES core.tenants,
    store_name  TEXT NOT NULL,
    city        TEXT,
    region      TEXT,
    opened_on   DATE
);

CREATE TABLE core.employees (
    employee_id  INT PRIMARY KEY,
    tenant_id    INT NOT NULL REFERENCES core.tenants,
    store_id     INT NOT NULL REFERENCES core.stores,
    full_name    TEXT NOT NULL,
    role         TEXT,
    phone        TEXT,
    joined_on    DATE NOT NULL,
    left_on      DATE,
    CHECK (left_on IS NULL OR left_on >= joined_on)
);

CREATE TABLE core.forms (
    form_id         INT PRIMARY KEY,
    tenant_id       INT NOT NULL REFERENCES core.tenants,
    form_name       TEXT NOT NULL,
    form_level      TEXT NOT NULL CHECK (form_level IN ('store', 'employee')),
    due_local_time  TIME NOT NULL,
    frequency       TEXT NOT NULL
);

CREATE TABLE core.courses (
    course_id       INT PRIMARY KEY,
    tenant_id       INT NOT NULL REFERENCES core.tenants,
    course_name     TEXT NOT NULL,
    total_chapters  INT NOT NULL
);

CREATE TABLE core.course_progress (
    employee_id         INT NOT NULL REFERENCES core.employees,
    course_id           INT NOT NULL REFERENCES core.courses,
    tenant_id           INT NOT NULL REFERENCES core.tenants,
    assigned_on         DATE NOT NULL,
    started_on          DATE,
    completed_on        DATE,
    chapters_completed  INT NOT NULL DEFAULT 0,
    PRIMARY KEY (employee_id, course_id)
);

-- Clean submissions. Local date/time are calculated once here, in each
-- tenant's own timezone, so every downstream query agrees on "which day".
CREATE TABLE core.form_submissions (
    submission_id       BIGINT PRIMARY KEY,
    tenant_id           INT NOT NULL REFERENCES core.tenants,
    form_id             INT NOT NULL REFERENCES core.forms,
    employee_id         INT NOT NULL REFERENCES core.employees,
    store_id            INT NOT NULL REFERENCES core.stores,
    submitted_at        TIMESTAMPTZ NOT NULL,
    submitted_local_ts  TIMESTAMP NOT NULL,
    local_date          DATE NOT NULL,
    status              TEXT NOT NULL,
    score               NUMERIC(5,1),
    channel             TEXT,
    is_on_time          BOOLEAN NOT NULL,
    is_odd_hour         BOOLEAN NOT NULL     -- submitted between 00:00 and 05:00 local time
);

CREATE TABLE core.reminders (
    reminder_id    BIGINT PRIMARY KEY,
    tenant_id      INT NOT NULL REFERENCES core.tenants,
    form_id        INT NOT NULL REFERENCES core.forms,
    employee_id    INT NOT NULL REFERENCES core.employees,
    store_id       INT NOT NULL REFERENCES core.stores,
    sent_at        TIMESTAMPTZ NOT NULL,
    local_date     DATE NOT NULL,
    reminder_type  TEXT NOT NULL CHECK (reminder_type IN ('reminder', 'escalation')),
    delivered      BOOLEAN NOT NULL
);

-- Quarantine: every raw submission that did not make it into core, and why.
CREATE TABLE core.rejected_submissions (
    submission_id     BIGINT,
    tenant_id         INT,
    form_id           INT,
    employee_id       INT,
    store_id          INT,
    submitted_at      TIMESTAMPTZ,
    status            TEXT,
    score             NUMERIC(5,1),
    channel           TEXT,
    rejection_reason  TEXT NOT NULL,
    rejected_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    reprocessed_at    TIMESTAMPTZ            -- set when a fixed row is moved into core
);
