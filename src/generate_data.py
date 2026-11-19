"""
Generate synthetic multi-tenant field operations data.

Creates CSV files in data/raw/ that simulate a SaaS platform where several client
companies (tenants) run daily checklists, staff check-ins, reminders and training
for their store teams. Real-world data problems are injected on purpose so the
pipeline has something to clean:

  - exact duplicate rows and "double-tap" duplicate submissions
  - submissions from employees that do not exist (orphans)
  - inconsistent status text ("Completed", " completed ", "COMPLETE")
  - timestamps in the future (device clock skew)
  - missing scores

All timestamps are written in UTC. Each tenant has its own timezone, so "which
day was this submitted?" has to be answered in the tenant's local time.

Usage:
    python src/generate_data.py                 # default size (~500k rows total)
    python src/generate_data.py --scale 3       # about 3x more stores and employees
    python src/generate_data.py --days 180      # longer history
"""

import argparse
import csv
import random
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from faker import Faker

TENANTS = [
    ("Spice Route Kitchens", "Quick Service Restaurant", "Asia/Kolkata"),
    ("UrbanMart Retail", "Retail", "Asia/Kolkata"),
    ("Desert Bloom Cafes", "Cafe", "Asia/Dubai"),
    ("Lion City Pharmacy", "Pharmacy", "Asia/Singapore"),
    ("Thames Fresh Grocers", "Grocery", "Europe/London"),
    ("Liberty Burger Co", "Quick Service Restaurant", "America/New_York"),
    ("Prairie Home Stores", "Retail", "America/Chicago"),
    ("Harbour Stay Hotels", "Hospitality", "Australia/Sydney"),
]

CITIES = {
    "Asia/Kolkata": ["Noida", "Gurugram", "Delhi", "Mumbai", "Bengaluru", "Pune", "Hyderabad", "Jaipur"],
    "Asia/Dubai": ["Dubai", "Abu Dhabi", "Sharjah"],
    "Asia/Singapore": ["Singapore"],
    "Europe/London": ["London", "Manchester", "Leeds", "Bristol"],
    "America/New_York": ["New York", "Boston", "Philadelphia", "Newark"],
    "America/Chicago": ["Chicago", "Dallas", "Houston", "Minneapolis"],
    "Australia/Sydney": ["Sydney", "Newcastle", "Wollongong"],
}

# (form name, level, due local time, frequency)
# level "store"    -> one submission expected per store per day
# level "employee" -> one submission expected per active employee per day
FORMS = [
    ("Opening Checklist", "store", time(10, 0), "daily"),
    ("Closing Checklist", "store", time(23, 0), "daily"),
    ("Shift Check-in", "employee", time(12, 0), "daily"),
]

COURSES = [
    ("Food Safety Basics", 6),
    ("Customer Service Excellence", 5),
    ("Store Opening SOP", 4),
    ("Fire & Emergency Safety", 8),
    ("Inventory Handling", 7),
]

STATUS_VARIANTS = ["completed", "Completed", " completed ", "COMPLETED", "complete"]


def write_csv(path: Path, header, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    print(f"  {path.name:<28} {len(rows):>10,} rows")


def to_utc(local_day: date, local_t: time, tz: ZoneInfo) -> datetime:
    return datetime.combine(local_day, local_t, tzinfo=tz).astimezone(timezone.utc)


def iso(ts: datetime) -> str:
    return ts.strftime("%Y-%m-%d %H:%M:%S+00")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scale", type=float, default=1.0, help="multiplies stores per tenant")
    ap.add_argument("--days", type=int, default=90, help="days of history")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default="data/raw")
    args = ap.parse_args()

    rnd = random.Random(args.seed)
    fake = Faker(["en_IN", "en_GB", "en_US"])
    Faker.seed(args.seed)
    out = Path(args.out)

    end_day = date.today() - timedelta(days=1)
    start_day = end_day - timedelta(days=args.days - 1)
    now_utc = datetime.now(timezone.utc)
    print(f"Generating {args.days} days of data: {start_day} to {end_day}")

    tenants, stores, employees, forms = [], [], [], []
    courses, progress, submissions, reminders = [], [], [], []

    store_id = employee_id = form_id = course_id = 0
    submission_id = reminder_id = 0

    for t_idx, (t_name, industry, tz_name) in enumerate(TENANTS, start=1):
        tz = ZoneInfo(tz_name)
        tenants.append([t_idx, t_name, industry, tz_name, "2024-01-15"])

        tenant_forms = []
        for f_name, level, due, freq in FORMS:
            form_id += 1
            forms.append([form_id, t_idx, f_name, level, due.strftime("%H:%M"), freq])
            tenant_forms.append((form_id, level, due))

        tenant_courses = []
        for c_name, chapters in rnd.sample(COURSES, k=rnd.randint(3, 5)):
            course_id += 1
            courses.append([course_id, t_idx, c_name, chapters])
            tenant_courses.append((course_id, chapters))

        n_stores = max(3, int(rnd.randint(20, 55) * args.scale))
        for s in range(n_stores):
            store_id += 1
            city = rnd.choice(CITIES[tz_name])
            region = f"Region {rnd.randint(1, 4)}"
            opened = start_day - timedelta(days=rnd.randint(30, 900))
            stores.append([store_id, t_idx, f"{t_name.split()[0]} {city} #{s + 1}", city, region, opened])
            store_reliability = rnd.betavariate(9, 1.3)  # most stores are good, a few are not

            # employees, with some joining and leaving during the period
            staff = []
            for e in range(rnd.randint(4, 10)):
                employee_id += 1
                role = "Store Manager" if e == 0 else rnd.choice(["Shift Lead", "Associate", "Associate"])
                joined = start_day - timedelta(days=rnd.randint(0, 600))
                if rnd.random() < 0.12:
                    joined = start_day + timedelta(days=rnd.randint(1, args.days - 5))
                left = None
                if rnd.random() < 0.10:
                    left = joined + timedelta(days=rnd.randint(10, 400))
                    if left > end_day:
                        left = None
                employees.append([employee_id, t_idx, store_id, fake.name(), role,
                                  f"+91{rnd.randint(7000000000, 9999999999)}", joined, left or ""])
                staff.append({"id": employee_id, "joined": joined, "left": left,
                              "reliability": rnd.betavariate(10, 1.3), "missed_yesterday": False})

            # training progress
            for c_id, chapters in tenant_courses:
                for emp in staff:
                    assigned = max(emp["joined"], start_day) + timedelta(days=rnd.randint(0, 20))
                    if assigned > end_day:
                        continue
                    started = completed = None
                    done_chapters = 0
                    if rnd.random() < 0.8:
                        started = assigned + timedelta(days=rnd.randint(0, 10))
                        done_chapters = rnd.randint(1, chapters)
                        if rnd.random() < 0.65:
                            done_chapters = chapters
                            completed = started + timedelta(days=rnd.randint(0, 25))
                    started = started if started and started <= end_day else None
                    completed = completed if completed and completed <= end_day and started else None
                    if not started:
                        done_chapters = 0
                    elif not completed and done_chapters == chapters:
                        done_chapters = chapters - 1
                    progress.append([emp["id"], c_id, t_idx, assigned, started or "", completed or "", done_chapters])

            # day-by-day activity
            day = start_day
            while day <= end_day:
                weekend_penalty = 0.06 if day.weekday() >= 5 else 0.0
                for f_id, level, due in tenant_forms:
                    if level == "store":
                        subjects = [(None, store_reliability - weekend_penalty, False)]
                    else:
                        subjects = [
                            (emp["id"], emp["reliability"] - weekend_penalty, emp["missed_yesterday"])
                            for emp in staff
                            if emp["joined"] <= day and (emp["left"] is None or day < emp["left"])
                        ]
                    for emp_id, p, missed_before in subjects:
                        # missing yesterday makes missing today more likely -> realistic streaks
                        p_submit = p - (0.2 if missed_before else 0.0)
                        submitter = emp_id or rnd.choice([e["id"] for e in staff])
                        due_utc = to_utc(day, due, tz)

                        # reminder 1 hour before due time for people who usually cut it close
                        reminded = rnd.random() < 0.35
                        if reminded:
                            reminder_id += 1
                            sent = due_utc - timedelta(hours=1)
                            reminders.append([reminder_id, t_idx, f_id, submitter, store_id, iso(sent),
                                              "reminder", rnd.random() > 0.03])
                            p_submit += 0.08  # reminders help a bit

                        submitted = rnd.random() < p_submit
                        if submitted:
                            offset_min = rnd.gauss(-75, 70) if not reminded else rnd.gauss(-25, 40)
                            ts = due_utc + timedelta(minutes=offset_min)
                            # business-day cutoff: a late submission still belongs to its own day
                            end_of_day = to_utc(day, time(23, 59), tz)
                            ts = min(ts, end_of_day - timedelta(seconds=rnd.randint(0, 600)))
                            if rnd.random() < 0.004:  # odd hour submission, e.g. 2 AM
                                ts = to_utc(day, time(rnd.randint(1, 4), rnd.randint(0, 59)), tz)
                            submission_id += 1
                            score = round(min(100, max(30, rnd.gauss(86, 9))), 1)
                            row = [submission_id, t_idx, f_id, submitter, store_id, iso(ts),
                                   rnd.choice(STATUS_VARIANTS) if rnd.random() < 0.25 else "completed",
                                   "" if rnd.random() < 0.02 else score,
                                   rnd.choice(["mobile_app", "mobile_app", "web", "whatsapp"])]
                            submissions.append(row)

                            # injected data problems
                            r = rnd.random()
                            if r < 0.006:  # exact duplicate row (loaded twice)
                                submissions.append(list(row))
                            elif r < 0.018:  # double-tap: new id, same content seconds later
                                submission_id += 1
                                dup = list(row)
                                dup[0] = submission_id
                                dup[5] = iso(min(ts + timedelta(seconds=rnd.randint(2, 40)), end_of_day))
                                submissions.append(dup)
                        else:
                            # missed -> escalate to the store manager 2 hours after due time
                            if rnd.random() < 0.7:
                                reminder_id += 1
                                reminders.append([reminder_id, t_idx, f_id, submitter, store_id,
                                                  iso(due_utc + timedelta(hours=2)), "escalation",
                                                  rnd.random() > 0.03])

                        if emp_id:
                            for emp in staff:
                                if emp["id"] == emp_id:
                                    emp["missed_yesterday"] = not submitted
                day += timedelta(days=1)

    # orphans: submissions from employee IDs the HR file doesn't have yet.
    # About 60% of them are real new joiners whose records arrive late
    # (late_employees.csv) and can be reprocessed; the rest stay rejected.
    orphan_home = {}
    for _ in range(int(len(submissions) * 0.002)):
        submission_id += 1
        src = rnd.choice([s for s in rnd.sample(submissions, 50) if s[3] < 9_000_000])
        orphan_id = 9_000_000 + rnd.randint(1, 400)
        tenant, store = orphan_home.setdefault(orphan_id, (src[1], src[4]))
        if (src[1], src[4]) != (tenant, store):
            continue
        submissions.append([submission_id, tenant, src[2], orphan_id, store,
                            src[5], "completed", src[7], src[8]])
    late_employees = [
        [oid, tenant, store, fake.name(), "Associate", f"+91{rnd.randint(7000000000, 9999999999)}",
         start_day, ""]
        for oid, (tenant, store) in sorted(orphan_home.items()) if rnd.random() < 0.6
    ]
    for _ in range(int(len(submissions) * 0.001)):
        submission_id += 1
        src = rnd.choice(submissions)
        future = now_utc + timedelta(days=rnd.randint(30, 400))
        submissions.append([submission_id, src[1], src[2], src[3], src[4], iso(future),
                            "completed", src[7], src[8]])
    rnd.shuffle(submissions)

    print("Writing CSV files:")
    write_csv(out / "tenants.csv", ["tenant_id", "tenant_name", "industry", "timezone", "onboarded_on"], tenants)
    write_csv(out / "stores.csv", ["store_id", "tenant_id", "store_name", "city", "region", "opened_on"], stores)
    write_csv(out / "employees.csv", ["employee_id", "tenant_id", "store_id", "full_name", "role", "phone",
                                      "joined_on", "left_on"], employees)
    write_csv(out / "forms.csv", ["form_id", "tenant_id", "form_name", "form_level", "due_local_time",
                                  "frequency"], forms)
    write_csv(out / "courses.csv", ["course_id", "tenant_id", "course_name", "total_chapters"], courses)
    write_csv(out / "course_progress.csv", ["employee_id", "course_id", "tenant_id", "assigned_on",
                                            "started_on", "completed_on", "chapters_completed"], progress)
    write_csv(out / "form_submissions.csv", ["submission_id", "tenant_id", "form_id", "employee_id", "store_id",
                                             "submitted_at", "status", "score", "channel"], submissions)
    write_csv(out / "reminders.csv", ["reminder_id", "tenant_id", "form_id", "employee_id", "store_id",
                                      "sent_at", "reminder_type", "delivered"], reminders)
    write_csv(out.parent / "late_arriving" / "late_employees.csv",
              ["employee_id", "tenant_id", "store_id", "full_name", "role", "phone", "joined_on", "left_on"],
              late_employees)
    print("Done.")


if __name__ == "__main__":
    main()
