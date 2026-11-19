"""
Measure query performance before and after indexing.

For each query in sql/benchmark_queries.sql this script:
  1. drops the indexes defined in sql/06_indexes.sql
  2. runs EXPLAIN (ANALYZE) several times and takes the median execution time
  3. creates the indexes again and repeats the measurement
Results are printed and saved to docs/benchmark_results.md, so you can quote
real numbers (and show the Seq Scan -> Index Scan change) in your README.

Usage:
    python src/benchmark.py            # 15 runs per query
    python src/benchmark.py --runs 30
"""

import argparse
import json
import re
import statistics
from datetime import datetime
from pathlib import Path

import psycopg

from run_pipeline import ROOT, SQL, conninfo


def load_queries():
    text = (SQL / "benchmark_queries.sql").read_text()
    parts = re.split(r"^-- name: (.+)$", text, flags=re.M)[1:]
    return [(parts[i].strip(), parts[i + 1].strip().rstrip(";")) for i in range(0, len(parts), 2)]


def index_names():
    return re.findall(r"CREATE INDEX IF NOT EXISTS (\w+)", (SQL / "06_indexes.sql").read_text())


def scan_types(plan):
    """Collect the scan node types from a JSON plan, e.g. {'Seq Scan', 'Index Scan'}."""
    found = set()
    def walk(node):
        if "Scan" in node["Node Type"]:
            found.add(node["Node Type"])
        for child in node.get("Plans", []):
            walk(child)
    walk(plan)
    return found


def measure(cur, sql, params, runs):
    times, scans = [], set()
    for i in range(runs + 1):
        cur.execute("EXPLAIN (ANALYZE, FORMAT JSON) " + sql, params)
        result = cur.fetchone()[0][0]
        if i == 0:
            continue  # warm-up run (loads data into cache)
        times.append(result["Execution Time"])
        scans |= scan_types(result["Plan"])
    return statistics.median(times), scans


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=15)
    args = ap.parse_args()

    with psycopg.connect(conninfo(), autocommit=True) as conn, conn.cursor() as cur:
        # pick realistic parameter values from the data
        cur.execute("SELECT MAX(local_date) FROM core.form_submissions")
        last_day = cur.fetchone()[0]
        cur.execute("""SELECT employee_id FROM core.form_submissions
                       GROUP BY employee_id ORDER BY COUNT(*) DESC LIMIT 1""")
        employee_id = cur.fetchone()[0]
        params = {
            "tenant_id": 1,
            "store_id": 1,
            "employee_id": employee_id,
            "last_day": last_day,
            "day_minus_7": last_day.fromordinal(last_day.toordinal() - 6),
            "day_minus_14": last_day.fromordinal(last_day.toordinal() - 13),
        }
        cur.execute("SELECT COUNT(*) FROM core.form_submissions")
        n_rows = cur.fetchone()[0]
        print(f"core.form_submissions: {n_rows:,} rows, {args.runs} runs per query\n")

        queries = load_queries()
        results = {}
        for idx in index_names():
            cur.execute(f"DROP INDEX IF EXISTS core.{idx}")
        cur.execute("ANALYZE core.form_submissions; ANALYZE core.reminders;")
        for name, sql in queries:
            results[name] = {"before": measure(cur, sql, params, args.runs)}

        cur.execute((SQL / "06_indexes.sql").read_text())
        for name, sql in queries:
            results[name]["after"] = measure(cur, sql, params, args.runs)

    lines = [
        "# Query benchmark results",
        "",
        f"Run on {datetime.now():%Y-%m-%d %H:%M} against {n_rows:,} rows in `core.form_submissions`. "
        f"Median of {args.runs} runs of `EXPLAIN ANALYZE`, after one warm-up run.",
        "",
        "| Query | Before (ms) | After (ms) | Improvement | Scan before | Scan after |",
        "|---|---:|---:|---:|---|---|",
    ]
    for name, r in results.items():
        (b, sb), (a, sa) = r["before"], r["after"]
        pct = (b - a) / b * 100
        lines.append(f"| {name} | {b:.2f} | {a:.2f} | {b / a:.0f}x ({pct:.1f}% less time) | "
                     f"{', '.join(sorted(sb))} | {', '.join(sorted(sa))} |")
    report = "\n".join(lines) + "\n"
    print(report)
    out = ROOT / "docs" / "benchmark_results.md"
    out.parent.mkdir(exist_ok=True)
    out.write_text(report)
    print(f"Saved to {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
