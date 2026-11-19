"""
Run the full pipeline: raw load -> transform -> quality checks -> analytics -> indexes.

Everything after the run log entry happens in ONE transaction: if any step or
any core data-quality check fails, the database is rolled back to its previous
good state and the run is recorded as 'failed' with the error message.

Usage:
    python src/run_pipeline.py                 # full run
    python src/run_pipeline.py --skip-indexes  # leave secondary indexes off (for benchmarking)
    python src/run_pipeline.py --reprocess     # load late employee records, reprocess quarantine

Connection settings come from environment variables (defaults match docker-compose.yml):
    PGHOST=localhost PGPORT=5432 PGDATABASE=fieldops PGUSER=analyst PGPASSWORD=analyst
"""

import argparse
import os
import sys
import time
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parent.parent
SQL = ROOT / "sql"

RAW_TABLES = ["tenants", "stores", "employees", "forms", "courses",
              "course_progress", "form_submissions", "reminders"]


def conninfo():
    return (f"host={os.getenv('PGHOST', 'localhost')} port={os.getenv('PGPORT', '5432')} "
            f"dbname={os.getenv('PGDATABASE', 'fieldops')} user={os.getenv('PGUSER', 'analyst')} "
            f"password={os.getenv('PGPASSWORD', 'analyst')}")


def run_sql_file(cur, name):
    t0 = time.perf_counter()
    cur.execute((SQL / name).read_text())
    print(f"  ✓ {name:<32} {time.perf_counter() - t0:6.2f}s")


def copy_csv(cur, table, path):
    with path.open("rb") as f, cur.copy(f"COPY {table} FROM STDIN WITH (FORMAT csv, HEADER true)") as cp:
        while chunk := f.read(1 << 20):
            cp.write(chunk)


def scalar(cur, q):
    cur.execute(q)
    return cur.fetchone()[0]


def print_quality_report(cur):
    cur.execute((SQL / "04_data_quality_checks.sql").read_text())
    rows = cur.fetchall()
    print("\nData quality report")
    print(f"  {'layer':<6} {'check':<55} {'rows':>8}  result")
    for layer, check, _sev, failed, result in rows:
        print(f"  {layer:<6} {check:<55} {failed:>8,}  {result}")
    failures = [r for r in rows if r[4] == "FAIL"]
    if failures:
        raise RuntimeError(f"{len(failures)} core data-quality check(s) failed: "
                           + "; ".join(r[1] for r in failures))


def full_run(args):
    data_dir = ROOT / args.data_dir
    missing = [t for t in RAW_TABLES if not (data_dir / f"{t}.csv").exists()]
    if missing:
        sys.exit(f"Missing CSV files in {data_dir}: {missing}. Run src/generate_data.py first.")

    with psycopg.connect(conninfo(), autocommit=True) as log_conn:
        log_conn.execute((SQL / "00_pipeline_runs.sql").read_text())
        run_id = log_conn.execute("INSERT INTO pipeline_runs DEFAULT VALUES RETURNING run_id").fetchone()[0]
        print(f"Pipeline run #{run_id} started")
        try:
            with psycopg.connect(conninfo()) as conn, conn.cursor() as cur:   # one transaction
                print("\n1. Create schemas")
                run_sql_file(cur, "01_raw_schema.sql")
                run_sql_file(cur, "02_core_schema.sql")

                print("\n2. Load raw CSVs")
                for t in RAW_TABLES:
                    t0 = time.perf_counter()
                    copy_csv(cur, f"raw.{t}", data_dir / f"{t}.csv")
                    n = scalar(cur, f"SELECT COUNT(*) FROM raw.{t}")
                    print(f"  ✓ raw.{t:<27} {n:>10,} rows {time.perf_counter() - t0:6.2f}s")

                print("\n3. Transform raw -> core")
                run_sql_file(cur, "03_transform.sql")

                print_quality_report(cur)

                print("\n4. Build analytics layer")
                run_sql_file(cur, "05_analytics_views.sql")

                if not args.skip_indexes:
                    print("\n5. Create indexes")
                    run_sql_file(cur, "06_indexes.sql")

                raw_rows = scalar(cur, "SELECT COUNT(*) FROM raw.form_submissions")
                loaded = scalar(cur, "SELECT COUNT(*) FROM core.form_submissions")
                rejected = scalar(cur, "SELECT COUNT(*) FROM core.rejected_submissions")
            # leaving the 'with' block commits the transaction

            log_conn.execute("""UPDATE pipeline_runs SET status='success', finished_at=now(),
                                raw_rows=%s, loaded_rows=%s, rejected_rows=%s WHERE run_id=%s""",
                             (raw_rows, loaded, rejected, run_id))
            print(f"\nRun #{run_id} succeeded: {raw_rows:,} raw submissions -> "
                  f"{loaded:,} loaded, {rejected:,} quarantined")
        except Exception as e:
            log_conn.execute("""UPDATE pipeline_runs SET status='failed', finished_at=now(),
                                error_message=%s WHERE run_id=%s""", (str(e)[:1000], run_id))
            print(f"\nRun #{run_id} FAILED and was rolled back: {e}")
            sys.exit(1)


def reprocess(args):
    late = ROOT / "data" / "late_arriving" / "late_employees.csv"
    if not late.exists():
        sys.exit(f"{late} not found. Run src/generate_data.py first.")
    with psycopg.connect(conninfo()) as conn, conn.cursor() as cur:
        before = scalar(cur, "SELECT COUNT(*) FROM core.rejected_submissions "
                             "WHERE rejection_reason='unknown_employee' AND reprocessed_at IS NULL")
        cur.execute("CREATE TEMP TABLE late_emp (LIKE raw.employees)")
        copy_csv(cur, "late_emp", late)
        cur.execute("INSERT INTO core.employees SELECT * FROM late_emp ON CONFLICT (employee_id) DO NOTHING")
        print(f"Loaded {cur.rowcount} late-arriving employee records")
        run_sql_file(cur, "07_reprocess_rejected.sql")
        recovered = scalar(cur, "SELECT COUNT(*) FROM core.rejected_submissions WHERE reprocessed_at IS NOT NULL")
        still = scalar(cur, "SELECT COUNT(*) FROM core.rejected_submissions "
                            "WHERE rejection_reason='unknown_employee' AND reprocessed_at IS NULL")
        print_quality_report(cur)
    print(f"\nReprocessing done: {before:,} rows were waiting for employee records, "
          f"{recovered:,} recovered into core, {still:,} still unknown")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default="data/raw")
    ap.add_argument("--skip-indexes", action="store_true")
    ap.add_argument("--reprocess", action="store_true")
    a = ap.parse_args()
    reprocess(a) if a.reprocess else full_run(a)
