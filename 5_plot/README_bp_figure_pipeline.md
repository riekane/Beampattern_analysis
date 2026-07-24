# Beampattern Figure Pipeline (Stage 5 — plotting)

Stage 5 of the bat beam-pattern pipeline. It turns the per-trial MATLAB
`bp_proc` outputs (`*_bp_proc.mat`, MATLAB v7.3 / HDF5) into the analysis
figures for a **two-arm (Y-maze) decision task**, and records every trial and
every call in one accumulating **SQLite database** with a flat **CSV/Parquet
mirror**.

**No MATLAB is required** — a pure-Python HDF5 reader parses the `.mat` files.
Beam directions are *not* recomputed here; the pipeline consumes the
MATLAB-computed `proc/beam_aim_az_el_deg` from Stage 3.

**Workflow:** edit the CONFIG block (or use the notebook form), run, and the
figures, stat table, and database update in place.

## Contents of `Analysis/Beampattern_analysis/5_plot/`

| File | Role |
|------|------|
| `bp_figure_pipeline.py` | Main pipeline — edit the CONFIG block and run. |
| `bp_figure_pipeline.ipynb` | Notebook version (inline figures + interactive trial-labeling form). Generated from the `.py`. |
| `gen_notebook.py` | Regenerates the `.ipynb` from the `.py` (single source of truth). |
| `plot_call_rate_by_zone.py` | Standalone call-rate-by-zone figures (own CONFIG). |
| `bp_db.py` | SQLite storage layer + CSV/Parquet mirror. |
| `beamlib.py` | Trial reader (`open_trial`, `ZONE_KEYS`) + geometry/beam library. |
| `h5read.py` | Pure-Python MATLAB v7.3 (HDF5) numeric reader. |

## Requirements

Python 3 with `numpy` + `matplotlib`. Optional:
`ipywidgets` (notebook labeling form; falls back to a paste-in template),
`pandas` + `pyarrow` (Parquet mirror; CSV is always written).

```bash
pip install numpy matplotlib          # required
pip install ipywidgets pandas pyarrow # optional
```

## Data locations (auto-detected — no paths to edit)

- **Input:** `Data/Beampattern_proc/<SUBJECT>/beampattern_output/<session>_T*_*bp_proc.mat`
- **Figure output:** `Analysis/Beampattern_analysis/5_plot/<batID>/` (per-subject, auto-created)
- **Database + mirror + call-rate PNGs:** `Analysis/Beampattern_analysis/5_plot/` (root)

Path selection falls back automatically to a mounted Linux copy when run through
a cloud bridge, so the same code runs on Windows or Linux unchanged.

## Running the figure pipeline

### Script

```bash
python bp_figure_pipeline.py
```

Edit the CONFIG block at the top:

```python
SUBJECT        = 'batA125'                    # one bat
SESSIONS       = ['20260710', '20260714']     # one or many 'YYYYMMDD'
ACROSS_SESSION = True   # True  = pool all listed sessions into ONE figure
                        # False = one figure per session

# Overlay multiple bats on the two beam-direction figures:
SUBJECTS       = None   # e.g. ['batA125', 'batFB80']; None = single subject
ACROSS_SUBJECT = False  # True + SUBJECTS -> one figure per type, each bat overlaid

# Restrict / annotate the beam-direction figures:
BEAM_SIDES     = None   # None = both sides; ['LEFT'] or ['RIGHT'] = one side only
FIG_NOTE       = ''     # optional italic caption

JUNCTION_VIS   = None   # extra visibility restriction on the junction figures
JUNCTION_ZONE  = 3      # the choice zone (past_y / junction)
TRIAL_LABELS   = {}     # filled by the form or hardcoded (see below)
```

### Notebook

Run `bp_figure_pipeline.ipynb` **from the `5_plot` folder** (it imports
`beamlib`/`h5read`/`bp_db` from the current directory). Run cells top to bottom:
edit CONFIG → run defs → run the **"Tag blocked trials"** form → run the final
cell. The form is interactive — **do not "Run All"**; fill it, click
**Save labels**, then run the last cell.

Regenerate the notebook after editing the script:

```bash
python gen_notebook.py
```

## What you get

Figures are saved to `5_plot/<batID>/` as `<batID>_<tag>_<figname>.png`, where
`tag` is the session (`20260714`) or `combined_0710_0714…` when pooled.

| Output | Description |
|--------|-------------|
| `*_junction_LR_split.png` | Beam (solid) + body heading (dashed) **lateralization index** vs time-to-arm; blue = went LEFT, orange = went RIGHT. Solid beam lifting off zero before the dashed body → the sonar leads the turn. Split-by-side traces show there is no left/right asymmetry artifact. |
| `*_junction_angle.png` | Same layout, y-axis = direction in **degrees from the maze midline** (0 = straight ahead, + toward LEFT). |
| `*_junction_predict.png` | Per-trial mean junction-zone beam lateralization; bar coloured by the arm actually taken. Title reports how many trials the junction beam predicts. |
| `*_stat_table.csv` | One row per trial (mirrors the `trials` table). Uses **all** trials, ignoring the figure visibility policy. |

Every run also writes `beampattern.db` plus `beampattern_trials.*` and
`beampattern_calls.*` (CSV always; Parquet if `pyarrow` is installed).

Add a figure: write `def fig_myplot(D, meta):` (see "Extending" below) and
append it to `FIGURES`.

## Sign & geometry conventions

- **Lateralization sign: LEFT = +, RIGHT = −**, applied consistently across
  every figure and the stat table (a deliberate, arbitrary choice — note it is
  *not* the perch-centered x-sign).
- `_lat = cos(az − bearing_to_LEFT) − cos(az − bearing_to_RIGHT)` → +1 fully
  toward LEFT arm, −1 fully toward RIGHT. Bounded, unitless, computed per trial
  from that trial's own arm geometry (so pooling across sessions is valid).
- `_ang` = signed **degrees** from the maze midline (0 = straight ahead,
  + toward LEFT).
- **Zones** (`beamlib.ZONE_KEYS`): `1 = approach`, `2 = inside_y (stem)`,
  `3 = past_y (junction)`, `4 = arm_purple (LEFT)`, `5 = arm_pink (RIGHT)`.
  LEFT arm = zone 4 = room +X = maze `right_wall` exit; RIGHT arm = zone 5 =
  room −X = maze `left_wall` exit.
- **Pre-flight ≠ zone 1.** *Pre-flight* = calls emitted before take-off (bat
  still on the perch: call index ≤ take-off frame) — a timing definition.
  *Zone 1* ("approach") = the in-flight spatial segment near the perch. They are
  reported as separate columns.

## Trial labeling (block condition)

On some trials a block occludes the target from the perch:

- **visible** from perch → can affect the PRE-FLIGHT call, not the choice.
- **invisible** from perch → can affect the CHOICE at the junction, not the
  pre-flight call.

**Figure policy:** invisible-from-perch blocked trials are **excluded** from all
junction figures (they can bias the choice) but are still stored in the
database. Visible-from-perch blocked trials **stay** and are drawn like normal
controls. Unlabeled trials are treated as `normal` (unblocked control).

Labels persist in the database, so once a trial is tagged the form pre-fills it
(marked ✓ saved) and a plain batch run picks it up automatically. Hardcode
alternative:

```python
TRIAL_LABELS['20260714'][5] = {'blocked': True, 'side': 'LEFT', 'vis': 'invisible'}
```

Safety rule: `write_labels()` is the only writer of the label columns
(`blocked`, `block_side`, `visibility`); a normal pipeline run updates only the
computed columns, so re-running never wipes a saved label.

## Database schema (`beampattern.db`)

One SQLite file accumulates across runs and subjects. Two tables; a flat
CSV/Parquet mirror (`beampattern_trials.*`, `beampattern_calls.*`) is written
next to it for MATLAB (`parquetread`, no toolbox).

### `trials` — one row per `(subject, session, trial)`

| Column | Type | Notes |
|--------|------|-------|
| `subject` `session` | TEXT | |
| `trial` | INTEGER | primary key with subject, session |
| `side_taken` | TEXT | `'LEFT'` / `'RIGHT'` (arm reached first) |
| `takeoff_frame` | INTEGER | launch frame index |
| `n_preflight_calls` | INTEGER | calls before take-off (on perch) |
| `preflight_lat` | REAL | mean lateralization of pre-flight calls |
| `n_zone1_calls` | INTEGER | zone-1 (approach) call count |
| `zone1_lat` | REAL | mean lateralization, zone 1 |
| `n_junction_calls` | INTEGER | junction-zone call count |
| `junction_lat` | REAL | mean lateralization at the junction |
| `junction_predicts_side` | INTEGER | 1 if sign of `junction_lat` matches the arm taken |
| `blocked` | INTEGER | label (0/1) |
| `block_side` | TEXT | label (`'LEFT'`/`'RIGHT'`/NULL) |
| `visibility` | TEXT | label (`'normal'`/`'visible'`/`'invisible'`) |

### `calls` — one row per call

| Column | Type | Notes |
|--------|------|-------|
| `subject` `session` | TEXT | |
| `trial` `call_index` | INTEGER | primary key with subject, session |
| `track_frame_idx` | INTEGER | index into the interpolated track |
| `call_time` | REAL | receive time (s) |
| `zone` | INTEGER | 1–5 |
| `zone_name` | TEXT | e.g. `past_y` |
| `bat_x` `bat_y` `bat_z` | REAL | bat position at call (m) |
| `beam_az_deg` `beam_el_deg` | REAL | beam aim (degrees) |
| `lat_index` | REAL | bounded LEFT(+)/RIGHT(−) index |
| `angle_from_midline_deg` | REAL | signed degrees from straight ahead |
| `is_preflight` `is_zone1` `is_junction` | INTEGER | flags (0/1) |

Reading it:

```python
import sqlite3, pandas as pd
con = sqlite3.connect("beampattern.db")
pd.read_sql("SELECT * FROM trials WHERE subject='batA125'", con)
pd.read_sql('''SELECT c.*, t.side_taken, t.visibility
               FROM calls c JOIN trials t USING(subject,session,trial)
               WHERE c.is_junction=1''', con)
```

The `<batID>_<tag>_stat_table.csv` columns are the `trials` computed + label
columns: `subject, session, trial, side_taken, blocked, block_side, visibility,
n_preflight_calls, preflight_lat, n_zone1_calls, zone1_lat, n_junction_calls,
junction_lat, junction_predicts_side`.

## Call-rate-by-zone figures (separate script)

```bash
python plot_call_rate_by_zone.py
```

Edit the `BATS` dict (colour, sessions, and `invisible_block` trials to drop per
the same visibility policy). For each bat it counts **all detected calls** (not
just localized ones) inside each zone's tracked time window and reports rate =
1 / median inter-call interval, averaged (± SEM) across trials. Using all
detected calls avoids undercounting at the fast turn into the arm, where ~50% of
calls lack a 3D track. Outputs to `5_plot/`:

- `<subject>_call_rate_by_zone.png` — single-bat bar chart (5 zones).
- `call_rate_by_zone_2bats.png` — two-bat line plot (arms pooled).

## Extending: add your own figure

Write `def fig_myplot(D, meta):` that saves a PNG to `meta['outdir']`, then
append it to `FIGURES`. Inputs:

- `D` — list of per-trial dicts, each with:
  `subject, session, trial`, `az`/`el` (beam degrees), `zone` (1–5),
  `ct` (call receive time, s), `bat` (3×N xyz at call, m), `idx`
  (track frame index), `ti`/`tt` (interpolated track + time),
  `tp`/`lp` (perch / target, m), `LEFT_exit`/`RIGHT_exit` (arm mouths, m),
  `takeoff` (launch frame), `side` (`'LEFT'`/`'RIGHT'`),
  `vis`/`blocked`/`block_side` (labels).
- `meta` — `subject, sessions, tag, title, outdir`.
- Helpers: `_lat(az, bx, by, LEFT_exit, RIGHT_exit)` (+LEFT/−RIGHT index),
  `_ang(...)` (signed degrees from midline), `_fig_trials(D)` (applies the
  visibility policy).

The database is always built from **all** loaded trials (no figure filtering),
so it stays the complete record regardless of the figure policy.

## Note on `beamlib`

The figure scripts use only `open_trial` and `ZONE_KEYS` from `beamlib`; beam
aim is read from the MATLAB-computed `proc/beam_aim_az_el_deg`. `beamlib` also
contains a standalone Python beam-estimation toolkit (`build_L35`,
`selected_rows`, `los_select`, `maze_walls`, `estbeam`) that the current figure
pipeline does not invoke.

## Sanity checks on a fresh run

Confirm (1) `calls` row count ≈ total calls across trials, (2)
`n_preflight_calls` looks sane (take-off detection can miss on some trials,
yielding ~0), (3) `angle_from_midline_deg` stays in a sensible range, and (4) if
`pyarrow` is absent only the CSV mirror is written (the run prints a note).

*Written by Rie Kaneko.*
