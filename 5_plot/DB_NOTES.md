# Beampattern database — quick notes

Every pipeline run now writes **one SQLite file** `beampattern.db` (in `5_plot/`) plus a
flat **Parquet + CSV mirror** (`beampattern_trials.*`, `beampattern_calls.*`) right next to it.
The DB accumulates across runs and across subjects — it is the single queryable record.

## Two tables

**`trials`** — one row per `(subject, session, trial)`
`subject, session, trial, side_taken, takeoff_frame,
n_preflight_calls, preflight_lat, n_zone1_calls, zone1_lat,
n_junction_calls, junction_lat, junction_predicts_side,
blocked, block_side, visibility`

**`calls`** — one row per call
`subject, session, trial, call_index, track_frame_idx, call_time,
zone, zone_name, bat_x, bat_y, bat_z, beam_az_deg, beam_el_deg,
lat_index, angle_from_midline_deg, is_preflight, is_zone1, is_junction`

`lat_index` = the bounded LEFT(+)/RIGHT(−) index; `angle_from_midline_deg` = the signed
degrees-from-straight-ahead value. Both are stored per call so you never have to recompute them.

## Labels persist (no more re-typing)

Block side / perch-view labels live in the `trials` table. The notebook form pre-loads them
(trials already tagged show up pre-filled, marked ✓ saved) and only blank trials need input.
A plain batch run of `bp_figure_pipeline.py` also picks up saved labels automatically.

Safety rule: `write_labels()` is the only thing that writes the label columns
(`blocked, block_side, visibility`). A normal pipeline run updates only the *computed* columns,
so re-running the batch script can never wipe a label you saved through the form.

## Figure policy (what's on the plots vs in the DB)

- **invisible**-from-perch blocked trials: **excluded** from all three junction figures
  (they can bias the choice) — but fully present in the DB.
- **visible**-from-perch blocked trials: **kept** on the figures, drawn like normal controls
  (no hatch) — their `visibility='visible'` label is in the DB for the pre-flight analysis.

## Reading it — Python

```python
import sqlite3, pandas as pd
con = sqlite3.connect(r"Z:\Rie\Analysis\Beampattern_analysis\5_plot\beampattern.db")

# per-trial summary for one bat
pd.read_sql("SELECT * FROM trials WHERE subject='batA125'", con)

# all junction calls, with the trial's outcome joined on
pd.read_sql('''SELECT c.*, t.side_taken, t.visibility
               FROM calls c JOIN trials t USING(subject,session,trial)
               WHERE c.is_junction=1''', con)

# sanity check: does the junction beam predict the arm taken? (control trials only)
pd.read_sql('''SELECT subject, SUM(junction_predicts_side) AS hits, COUNT(*) AS n
               FROM trials WHERE visibility='normal' AND junction_predicts_side IS NOT NULL
               GROUP BY subject''', con)
```

Or just read the mirror with no SQL: `pd.read_parquet(".../beampattern_calls.parquet")`.

## Reading it — MATLAB

No Database Toolbox needed if you use the Parquet mirror:

```matlab
T = parquetread("Z:\Rie\Analysis\Beampattern_analysis\5_plot\beampattern_trials.parquet");
C = parquetread("Z:\Rie\Analysis\Beampattern_analysis\5_plot\beampattern_calls.parquet");
jc = C(C.is_junction==1, :);                 % all junction calls
```

If you *do* have the Database Toolbox you can hit the SQLite file directly:

```matlab
conn = sqlite("Z:\Rie\Analysis\Beampattern_analysis\5_plot\beampattern.db","readonly");
T = sqlread(conn,"trials");
close(conn);
```

(Without the toolbox, the free `mksqlite` MEX also works — but the Parquet mirror is the
zero-dependency path.)

## First real-data run — what to sanity-check

The pipeline logic was verified on synthetic trials; the first run on real `.mat` data should
confirm: (1) `calls` row count ≈ total calls across trials, (2) `n_preflight_calls` looks sane
(take-off detection), (3) `angle_from_midline_deg` stays within a sensible range, and
(4) if `pip install pyarrow` isn't present, only the CSV mirror is written (the run prints a note).
