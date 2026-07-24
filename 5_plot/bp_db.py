#!/usr/bin/env python3
r"""
bp_db.py  --  storage layer for the beampattern pipeline
========================================================
A tiny, dependency-light layer that persists per-trial condition labels and
per-call beam data into ONE SQLite file, plus a flat Parquet/CSV mirror so the
same tables are readable from MATLAB with no toolbox.

Why it exists
-------------
* keeps block/side/visibility labels so the notebook form stops re-asking every run
* one queryable place for sanity checks + downstream grubbing (SQL joins)
* Parquet mirror = MATLAB `parquetread` with NO Database Toolbox needed
  (SQLite itself needs Database Toolbox or the free `mksqlite` MEX in MATLAB)

Two tables
----------
trials : one row per (subject, session, trial)  -- condition + per-trial summary
calls  : one row per call                       -- bat position, zone, beam dir

Design rule (important): trial LABEL columns (blocked/block_side/visibility) are
written ONLY by write_labels(). write_records() updates only the *computed*
columns on an existing trial, so a plain batch run of the pipeline can never
clobber labels you saved earlier through the form.

Pure-stdlib for SQLite. Parquet uses pandas+pyarrow if present; otherwise it
silently falls back to CSV only (and says so).
"""
import os, sqlite3

# ---- label columns are owned by the form; computed columns by the pipeline ----
LABEL_COLS    = ['blocked', 'block_side', 'visibility']
COMPUTED_COLS = ['side_taken', 'takeoff_frame',
                 'n_preflight_calls', 'preflight_lat',
                 'n_zone1_calls', 'zone1_lat',
                 'n_junction_calls', 'junction_lat', 'junction_predicts_side']
TRIAL_COLS = ['subject', 'session', 'trial'] + COMPUTED_COLS + LABEL_COLS
CALL_COLS  = ['subject', 'session', 'trial', 'call_index', 'track_frame_idx',
              'call_time', 'zone', 'zone_name', 'bat_x', 'bat_y', 'bat_z',
              'beam_az_deg', 'beam_el_deg', 'lat_index', 'angle_from_midline_deg',
              'is_preflight', 'is_zone1', 'is_junction']

_SCHEMA = """
CREATE TABLE IF NOT EXISTS trials(
    subject TEXT NOT NULL,
    session TEXT NOT NULL,
    trial   INTEGER NOT NULL,
    side_taken TEXT,
    takeoff_frame INTEGER,
    n_preflight_calls INTEGER,
    preflight_lat REAL,
    n_zone1_calls INTEGER,
    zone1_lat REAL,
    n_junction_calls INTEGER,
    junction_lat REAL,
    junction_predicts_side INTEGER,
    blocked INTEGER DEFAULT 0,
    block_side TEXT,
    visibility TEXT DEFAULT 'normal',
    PRIMARY KEY (subject, session, trial)
);
CREATE TABLE IF NOT EXISTS calls(
    subject TEXT NOT NULL,
    session TEXT NOT NULL,
    trial   INTEGER NOT NULL,
    call_index INTEGER NOT NULL,
    track_frame_idx INTEGER,
    call_time REAL,
    zone INTEGER,
    zone_name TEXT,
    bat_x REAL, bat_y REAL, bat_z REAL,
    beam_az_deg REAL, beam_el_deg REAL,
    lat_index REAL,
    angle_from_midline_deg REAL,
    is_preflight INTEGER,
    is_zone1 INTEGER,
    is_junction INTEGER,
    PRIMARY KEY (subject, session, trial, call_index)
);
CREATE INDEX IF NOT EXISTS ix_calls_trial ON calls(subject, session, trial);
CREATE INDEX IF NOT EXISTS ix_calls_zone  ON calls(subject, zone);
"""


def connect(db_path):
    """Open (creating if needed) the SQLite file and ensure the schema exists."""
    d = os.path.dirname(os.path.abspath(db_path))
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(_SCHEMA)
    return conn


# ------------------------------- labels --------------------------------------
def read_labels(db_path, subject, sessions):
    """Return {session: {trial: {'blocked':bool,'side':str|None,'vis':str}}} for
    trials that have a non-default label saved. Empty dict if the DB is absent."""
    out = {}
    if not os.path.exists(db_path):
        return out
    conn = connect(db_path)
    try:
        qmarks = ','.join('?' * len(sessions))
        cur = conn.execute(
            "SELECT session, trial, blocked, block_side, visibility "
            "FROM trials WHERE subject=? AND session IN (%s) "
            "AND (blocked=1 OR (visibility IS NOT NULL AND visibility!='normal') "
            "OR block_side IS NOT NULL)" % qmarks,
            [subject] + list(sessions))
        for session, trial, blocked, side, vis in cur.fetchall():
            out.setdefault(session, {})[int(trial)] = {
                'blocked': bool(blocked),
                'side': side,
                'vis': vis or 'normal'}
    finally:
        conn.close()
    return out


def write_labels(db_path, subject, labels):
    """Upsert ONLY the label columns. labels is the TRIAL_LABELS dict shape:
    {session: {trial: {'blocked':bool,'side':str|None,'vis':str}}}."""
    conn = connect(db_path)
    n = 0
    try:
        for session, trials in labels.items():
            for trial, info in trials.items():
                conn.execute(
                    "INSERT INTO trials(subject, session, trial, blocked, block_side, visibility) "
                    "VALUES(?,?,?,?,?,?) "
                    "ON CONFLICT(subject, session, trial) DO UPDATE SET "
                    "blocked=excluded.blocked, block_side=excluded.block_side, "
                    "visibility=excluded.visibility",
                    (subject, session, int(trial),
                     int(bool(info.get('blocked'))),
                     info.get('side'),
                     info.get('vis', 'normal')))
                n += 1
        conn.commit()
    finally:
        conn.close()
    return n


# --------------------------- trials + calls ----------------------------------
def write_records(db_path, trial_rows, call_rows):
    """Upsert trial summaries (computed cols only on conflict, so labels are
    never clobbered) and replace all calls for each trial present."""
    conn = connect(db_path)
    try:
        set_clause = ', '.join('%s=excluded.%s' % (c, c) for c in COMPUTED_COLS)
        tcols = ','.join(TRIAL_COLS)
        tqs = ','.join('?' * len(TRIAL_COLS))
        for r in trial_rows:
            conn.execute(
                "INSERT INTO trials(%s) VALUES(%s) "
                "ON CONFLICT(subject, session, trial) DO UPDATE SET %s"
                % (tcols, tqs, set_clause),
                [r.get(c) for c in TRIAL_COLS])

        # replace calls per (subject, session, trial) that appears in call_rows
        seen = {(r['subject'], r['session'], r['trial']) for r in call_rows}
        for s, se, t in seen:
            conn.execute("DELETE FROM calls WHERE subject=? AND session=? AND trial=?",
                         (s, se, t))
        ccols = ','.join(CALL_COLS)
        cqs = ','.join('?' * len(CALL_COLS))
        conn.executemany(
            "INSERT INTO calls(%s) VALUES(%s)" % (ccols, cqs),
            [[r.get(c) for c in CALL_COLS] for r in call_rows])
        conn.commit()
    finally:
        conn.close()


# ------------------------------ flat mirror ----------------------------------
def export_flat(db_path, out_dir, prefix='beampattern'):
    """Mirror both tables to <out_dir>/<prefix>_trials.* and _calls.* .
    Writes Parquet when pandas+pyarrow are available (MATLAB reads it natively
    with no toolbox); always also writes CSV. Returns the list of files made."""
    os.makedirs(out_dir, exist_ok=True)
    made = []
    conn = connect(db_path)
    try:
        try:
            import pandas as pd
            for name in ('trials', 'calls'):
                df = pd.read_sql_query("SELECT * FROM %s ORDER BY subject, session, trial" % name, conn)
                csv_path = os.path.join(out_dir, '%s_%s.csv' % (prefix, name))
                df.to_csv(csv_path, index=False); made.append(csv_path)
                try:
                    pq_path = os.path.join(out_dir, '%s_%s.parquet' % (prefix, name))
                    df.to_parquet(pq_path, index=False); made.append(pq_path)
                except Exception as e:
                    print('    [bp_db] parquet skipped (%s) -- CSV written. `pip install pyarrow` for parquet.' % type(e).__name__)
        except ImportError:
            import csv as _csv
            for name in ('trials', 'calls'):
                cur = conn.execute("SELECT * FROM %s ORDER BY subject, session, trial" % name)
                cols = [d[0] for d in cur.description]
                csv_path = os.path.join(out_dir, '%s_%s.csv' % (prefix, name))
                with open(csv_path, 'w', newline='') as f:
                    w = _csv.writer(f); w.writerow(cols); w.writerows(cur.fetchall())
                made.append(csv_path)
            print('    [bp_db] pandas not found -- wrote CSV only (no parquet).')
    finally:
        conn.close()
    return made
