-- =====================================================================
-- 05_analytics_views.sql
-- Analytics layer that Metabase reads from.
--
-- The key idea: compliance = submitted / EXPECTED. Missing submissions leave
-- no row behind, so we first build every expected (subject, form, day) and
-- LEFT JOIN actual submissions onto it. That base is a materialized view,
-- refreshed after each load, so dashboards stay fast.
-- =====================================================================

CREATE SCHEMA analytics;

-- ---------------------------------------------------------------------
-- 1. Base fact: one row per EXPECTED submission (materialized)
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.fact_expected_vs_actual AS
WITH tenant_period AS (
    -- the reporting window per tenant, in that tenant's local dates
    SELECT tenant_id, MIN(local_date) AS first_day, MAX(local_date) AS last_day
    FROM core.form_submissions
    GROUP BY tenant_id
),
days AS (
    SELECT tp.tenant_id, d::date AS local_date
    FROM tenant_period tp,
         generate_series(tp.first_day, tp.last_day, interval '1 day') AS d
),
expected AS (
    -- store-level forms: every open store, every day
    SELECT d.tenant_id, f.form_id, f.form_name, f.form_level, s.store_id,
           NULL::INT AS employee_id, d.local_date
    FROM days d
    JOIN core.forms  f ON f.tenant_id = d.tenant_id AND f.form_level = 'store'
    JOIN core.stores s ON s.tenant_id = d.tenant_id AND s.opened_on <= d.local_date
    UNION ALL
    -- employee-level forms: every ACTIVE employee, every day
    SELECT d.tenant_id, f.form_id, f.form_name, f.form_level, e.store_id,
           e.employee_id, d.local_date
    FROM days d
    JOIN core.forms     f ON f.tenant_id = d.tenant_id AND f.form_level = 'employee'
    JOIN core.employees e ON e.tenant_id = d.tenant_id
                         AND e.joined_on <= d.local_date
                         AND (e.left_on IS NULL OR d.local_date < e.left_on)
)
SELECT
    x.tenant_id, x.form_id, x.form_name, x.form_level, x.store_id, x.employee_id, x.local_date,
    s.submission_id,
    (s.submission_id IS NOT NULL)          AS is_submitted,
    COALESCE(s.is_on_time, FALSE)          AS is_on_time,
    s.score
FROM expected x
LEFT JOIN core.form_submissions s
       ON s.form_id = x.form_id
      AND s.local_date = x.local_date
      AND (   (x.form_level = 'store'    AND s.store_id    = x.store_id)
           OR (x.form_level = 'employee' AND s.employee_id = x.employee_id));

CREATE INDEX ON analytics.fact_expected_vs_actual (tenant_id, local_date);
CREATE INDEX ON analytics.fact_expected_vs_actual (employee_id, local_date);
CREATE INDEX ON analytics.fact_expected_vs_actual (store_id, local_date);

-- ---------------------------------------------------------------------
-- 2. Daily compliance per tenant and form
-- ---------------------------------------------------------------------
CREATE VIEW analytics.daily_compliance AS
SELECT
    t.tenant_name,
    f.tenant_id,
    f.form_name,
    f.local_date,
    COUNT(*)                                              AS expected,
    COUNT(*) FILTER (WHERE f.is_submitted)                AS submitted,
    COUNT(*) FILTER (WHERE f.is_on_time)                  AS on_time,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_submitted) / COUNT(*), 1) AS compliance_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_on_time)   / COUNT(*), 1) AS on_time_pct
FROM analytics.fact_expected_vs_actual f
JOIN core.tenants t USING (tenant_id)
GROUP BY t.tenant_name, f.tenant_id, f.form_name, f.local_date;

-- ---------------------------------------------------------------------
-- 3. Weekly store ranking within each tenant (RANK + NTILE)
-- ---------------------------------------------------------------------
CREATE VIEW analytics.store_weekly_ranking AS
WITH weekly AS (
    SELECT
        f.tenant_id,
        f.store_id,
        date_trunc('week', f.local_date)::date AS week_start,
        ROUND(100.0 * AVG(f.is_submitted::int), 1) AS compliance_pct,
        ROUND(100.0 * AVG(f.is_on_time::int), 1)   AS on_time_pct
    FROM analytics.fact_expected_vs_actual f
    GROUP BY 1, 2, 3
)
SELECT
    t.tenant_name,
    s.store_name,
    s.city,
    s.region,
    w.week_start,
    w.compliance_pct,
    w.on_time_pct,
    RANK()   OVER (PARTITION BY w.tenant_id, w.week_start ORDER BY w.compliance_pct DESC) AS rank_in_tenant,
    NTILE(4) OVER (PARTITION BY w.tenant_id, w.week_start ORDER BY w.compliance_pct DESC) AS quartile,
    w.compliance_pct - LAG(w.compliance_pct) OVER (PARTITION BY w.store_id ORDER BY w.week_start)
        AS change_vs_last_week
FROM weekly w
JOIN core.tenants t USING (tenant_id)
JOIN core.stores  s USING (store_id);

-- ---------------------------------------------------------------------
-- 4. Missed-day streaks per employee (gaps and islands)
--    Consecutive missed days share the same (date - row_number) value.
-- ---------------------------------------------------------------------
CREATE VIEW analytics.employee_missed_streaks AS
WITH missed AS (
    SELECT
        tenant_id, store_id, employee_id, form_name, local_date,
        local_date - (ROW_NUMBER() OVER (PARTITION BY employee_id, form_id ORDER BY local_date))::int
            AS streak_group
    FROM analytics.fact_expected_vs_actual
    WHERE form_level = 'employee' AND NOT is_submitted
),
streaks AS (
    SELECT tenant_id, store_id, employee_id, form_name,
           MIN(local_date) AS streak_start,
           MAX(local_date) AS streak_end,
           COUNT(*)        AS days_missed
    FROM missed
    GROUP BY tenant_id, store_id, employee_id, form_name, streak_group
),
last_day AS (
    SELECT tenant_id, MAX(local_date) AS last_day
    FROM analytics.fact_expected_vs_actual
    GROUP BY tenant_id
)
SELECT
    t.tenant_name, s.store_name, e.full_name, e.role,
    k.form_name, k.streak_start, k.streak_end, k.days_missed,
    (k.streak_end = ld.last_day) AS is_ongoing
FROM streaks k
JOIN last_day       ld USING (tenant_id)
JOIN core.tenants   t USING (tenant_id)
JOIN core.stores    s USING (store_id)
JOIN core.employees e USING (employee_id)
WHERE k.days_missed >= 3;

-- ---------------------------------------------------------------------
-- 5. Reminder effectiveness: did a submission follow, and how fast?
-- ---------------------------------------------------------------------
CREATE VIEW analytics.reminder_effectiveness AS
SELECT
    t.tenant_name,
    r.reminder_id,
    r.reminder_type,
    fm.form_name,
    r.local_date,
    r.delivered,
    s.submission_id IS NOT NULL                                     AS submitted_after,
    ROUND(EXTRACT(EPOCH FROM (s.submitted_at - r.sent_at)) / 60.0)  AS minutes_to_submit
FROM core.reminders r
JOIN core.tenants t  ON t.tenant_id = r.tenant_id
JOIN core.forms   fm ON fm.form_id = r.form_id
LEFT JOIN LATERAL (
    SELECT sub.submission_id, sub.submitted_at
    FROM core.form_submissions sub
    WHERE sub.form_id = r.form_id
      AND sub.local_date = r.local_date
      AND sub.submitted_at >= r.sent_at
      AND (   (fm.form_level = 'store'    AND sub.store_id    = r.store_id)
           OR (fm.form_level = 'employee' AND sub.employee_id = r.employee_id))
    ORDER BY sub.submitted_at
    LIMIT 1
) s ON TRUE
WHERE r.reminder_type = 'reminder';

CREATE VIEW analytics.reminder_summary AS
SELECT
    tenant_name,
    form_name,
    COUNT(*)                                                    AS reminders_sent,
    ROUND(100.0 * AVG(submitted_after::int), 1)                 AS conversion_pct,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY minutes_to_submit)
        FILTER (WHERE submitted_after)                          AS median_minutes_to_submit
FROM analytics.reminder_effectiveness
WHERE delivered
GROUP BY tenant_name, form_name;

-- ---------------------------------------------------------------------
-- 6. Training funnel per course
-- ---------------------------------------------------------------------
CREATE VIEW analytics.training_funnel AS
SELECT
    t.tenant_name,
    c.course_name,
    COUNT(*)                                                          AS assigned,
    COUNT(p.started_on)                                               AS started,
    COUNT(p.completed_on)                                             AS completed,
    ROUND(100.0 * COUNT(p.started_on)   / COUNT(*), 1)                AS started_pct,
    ROUND(100.0 * COUNT(p.completed_on) / COUNT(*), 1)                AS completed_pct,
    ROUND(AVG(p.completed_on - p.assigned_on), 1)                     AS avg_days_to_complete,
    COUNT(*) FILTER (WHERE p.completed_on IS NULL
                       AND p.assigned_on < CURRENT_DATE - 30)         AS overdue_30_days
FROM core.course_progress p
JOIN core.courses c USING (course_id)
JOIN core.tenants t ON t.tenant_id = p.tenant_id
GROUP BY t.tenant_name, c.course_name;

-- ---------------------------------------------------------------------
-- 7. Week-over-week trend per tenant
-- ---------------------------------------------------------------------
CREATE VIEW analytics.weekly_trend AS
WITH weekly AS (
    SELECT tenant_id,
           date_trunc('week', local_date)::date AS week_start,
           ROUND(100.0 * AVG(is_submitted::int), 1) AS compliance_pct
    FROM analytics.fact_expected_vs_actual
    GROUP BY 1, 2
)
SELECT t.tenant_name, w.week_start, w.compliance_pct,
       w.compliance_pct - LAG(w.compliance_pct) OVER (PARTITION BY w.tenant_id ORDER BY w.week_start)
           AS change_pts,
       ROUND(AVG(w.compliance_pct) OVER (PARTITION BY w.tenant_id ORDER BY w.week_start
                                         ROWS BETWEEN 3 PRECEDING AND CURRENT ROW), 1)
           AS rolling_4wk_avg
FROM weekly w
JOIN core.tenants t USING (tenant_id);

-- ---------------------------------------------------------------------
-- 8. Data quality summary (for a dashboard card)
-- ---------------------------------------------------------------------
CREATE VIEW analytics.data_quality_summary AS
SELECT rejection_reason,
       COUNT(*) AS rows_rejected,
       COUNT(*) FILTER (WHERE reprocessed_at IS NOT NULL) AS rows_reprocessed
FROM core.rejected_submissions
GROUP BY rejection_reason;
