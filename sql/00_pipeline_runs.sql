-- =====================================================================
-- 00_pipeline_runs.sql
-- Monitoring table: one row per pipeline run. Lives in the public schema so it
-- survives the full refresh of raw/core/analytics.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.pipeline_runs (
    run_id          SERIAL PRIMARY KEY,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at     TIMESTAMPTZ,
    status          TEXT NOT NULL DEFAULT 'running',   -- running / success / failed
    raw_rows        INT,
    loaded_rows     INT,
    rejected_rows   INT,
    error_message   TEXT
);
