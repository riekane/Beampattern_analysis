# Beampattern Figure Pipeline — Project Context / Handoff

Portable context for continuing this work on another machine. Human- and Claude-readable.
(If you want a Claude session to auto-load this, drop it in the repo root as `CLAUDE.md`.)

---

## What this is
A no-MATLAB **Python** pipeline that turns per-trial beampattern results
(`*bp_proc.mat`, MATLAB v7.3 / HDF5) into junction/choice figures + a per-trial stat
table, for a bat **two-arm maze decision task**. Two synced entry points live in `5_plot/`:

- `bp_figure_pipeline.py`  — script: edit the CONFIG block, run.
- `bp_figure_pipeline.ipynb` — notebook version (MATLAB-live-script style; interactive
  trial-labeling form; figures show inline). Generated from the `.py`.

## Files & dependencies
Folder: `Z:\Rie\Analysis\Beampattern_analysis\5_plot\`

- `bp_figure_pipeline.py` / `.ipynb` — the pipeline (keep in sync; `.ipynb` is generated from `.py`).
- `beamlib.py` — trial reader (`open_trial`) and `ZONE_KEYS`.
- `h5read.py` — pure-Python MATLAB v7.3 (HDF5) reader (no MATLAB needed).

Python deps: `numpy`, `matplotlib`. Optional: `ipywidgets` (for the labeling form; if
missing, the form cell prints a paste-in template instead).
**Run the notebook FROM the `5_plot` folder** — it imports `beamlib`/`h5read` from the
current directory (`os.getcwd()`).

## Data locations (auto-detected — no paths to edit)
- Input:  `Z:\Rie\Data\Beampattern_proc\<SUBJECT>\beampattern_output\<session>_T*_*bp_proc.mat`
- Output: `Z:\Rie\Analysis\Beampattern_analysis\5_plot\<batID>\`  (per-subject subfolder, auto-created)

`_pick()` also falls back to `/sessions/*/mnt/...` copies when run through the cloud bridge.

## CONFIG knobs (top of file / CONFIG cell)
- `SUBJECT` — e.g. `'batA125'`, `'batFB80'`
- `SESSIONS` — list of `'YYYYMMDD'`
- `ACROSS_SESSION` — `True` pools all listed sessions into ONE figure; `False` = one figure per session
- `JUNCTION_VIS` — `None` (all trials) or e.g. `['invisible']` to restrict the choice/junction figures
- `JUNCTION_ZONE = 3`
- `TRIAL_LABELS` — filled by the form (or hardcode; see below)

---

## Zone scheme (from `beamlib.ZONE_KEYS`)
`1=approach  2=inside_y  3=past_y(junction)  4=arm_purple(LEFT)  5=arm_pink(RIGHT)`

Arm / coordinate mapping (from the code):
LEFT arm = arm_purple = zone 4 = room **+X** = maze `right_wall` exit;
RIGHT arm = arm_pink = zone 5 = room **−X** = `left_wall` exit.
Perch(tp)-centered frame: room +X = LEFT arm = tp-centered **−x**, so **perch-centered +x points RIGHT**.

## Sign conventions — IMPORTANT
- All figures + the stat table use a **lateralization sign of LEFT = +, RIGHT = −**.
  This is a deliberate, arbitrary choice (NOT the perch-centered x-sign) applied consistently.
- `_lat(az,…)` index = `cos(az − bearing_to_LEFT) − cos(az − bearing_to_RIGHT)`
  → +1 fully toward LEFT arm, −1 fully toward RIGHT. Bounded, unitless.
- `_ang(az,…)` = signed **angle in degrees** from the maze **midline** (the bisector of the two
  arm bearings): 0 = straight ahead, + toward LEFT, − toward RIGHT. Physical units; robust to
  coordinate orientation (it signs itself from each trial's arm geometry).
- To switch to **right = +** (match perch-centered x): negate `_lat` and `_ang` returns and swap the
  `(+)/(−)` text in the two y-labels. `junction_predicts_side` is sign-independent (unaffected).

## Pre-flight vs zone 1 — they are DIFFERENT (reported separately)
- **pre-flight** = calls emitted **before take-off** (bat still on the perch), detected per trial as
  `call idx <= takeoff frame`. A *timing* definition, not a spatial zone.
- **zone 1** ('approach') = the spatial in-flight segment near the perch.

Take-off frame from `takeoff_frame()` (speed ≥ 0.5 m/s, descending vz, sustained departure). If
take-off isn't cleanly detected on a trial, `n_preflight_calls` can be ~0 — sanity-check the counts.

---

## Figures produced (into `5_plot/<batID>/`)
`tag` = the session (`20260710`) or `combined_0710_0714…` when pooled.

1. `<batID>_<tag>_junction_LR_split.png` — beam (solid) + body heading (dashed) **lateralization
   index** vs time; blue = went LEFT, orange = went RIGHT. Split-by-side (the two symmetric traces
   show there's no left/right asymmetry artifact). Beam lifting off zero before body = **sonar leads
   the turn**.
2. `<batID>_<tag>_junction_angle.png` — same layout, but y = actual **direction in DEGREES from the
   midline** (0 = straight ahead). Beam and body sit on one identical angular axis.
3. `<batID>_<tag>_junction_predict.png` — per-trial mean junction (zone 3) lateralization bar; bar
   color = arm actually taken; hatch = blocked trial (`//` invisible, `..` visible). Title shows the
   predict count.
4. `<batID>_<tag>_stat_table.csv` — one row per trial (columns below). Uses **ALL** trials
   (ignores `JUNCTION_VIS`).

Add a figure: write `fig_*(D, meta)` and append it to the `FIGURES` list. Current:
`FIGURES = [fig_junction_LR_split, fig_junction_angle, fig_junction_predict_bar, fig_stat_table]`

## Stat table columns
`subject, session, trial, side_taken, blocked, block_side, visibility,
n_preflight_calls, preflight_lat, n_zone1_calls, zone1_lat,
n_junction_calls, junction_lat, junction_predicts_side`

- `*_lat` = mean lateralization index (+LEFT / −RIGHT) over that call subset.
- `junction_predicts_side` = 1 if sign of `junction_lat` matches the arm actually taken.

---

## Trial labeling (blocked / visibility / block side)
Manipulation: a block occludes the target from the perch on some trials.
- **visible** from perch → can affect the PRE-FLIGHT call, NOT the choice.
- **invisible** from perch → can affect the CHOICE at the junction, NOT the pre-flight call.

Per trial you record the **block side** (LEFT/RIGHT) and the **perch view** (visible/invisible).
Unlabeled trials = `normal` (unblocked control).

Data model:
`TRIAL_LABELS[session][trial] = {'blocked': True, 'side': 'LEFT'/'RIGHT'/None, 'vis': 'visible'/'invisible'/'normal'}`

### The form (notebook)
Run CONFIG, then the **"Tag blocked trials"** cell → an inline `ipywidgets` form lists each detected
trial with two dropdowns (**block side**, **perch view**), both defaulting to **blank (—)**. Leave
normal trials blank; set only the blocked ones; click **Save labels**; then run the final cell.
- Blank perch view is stored as `normal` automatically.
- **Don't use "Run All"** — the form is interactive (fill it, Save, then run the last cell).
- No `ipywidgets` → the cell prints a `TRIAL_LABELS` template to paste into the CONFIG cell.

---

## Regenerating the notebook from the script
The `.ipynb` is built from the `.py`. Cells: markdown → imports (`%matplotlib inline`) → CONFIG →
all defs → form call (`label_trials()`) → `run(...)`. Transforms applied during generation:
`os.path.dirname(os.path.abspath(__file__))` → `os.getcwd()`, and `plt.close(fig)` → `plt.show()`
(so figures render inline). Preferred workflow: edit the `.py`, then regenerate the `.ipynb`
(or keep both edited in lockstep).

## Key design decisions (the "why")
- **Per-batID output subfolders** — keep subjects separate.
- **LEFT = +** across every figure — chosen for consistency. (User is aware the perch-centered
  convention is right = +; deliberately not flipped so the two figures agree.)
- **Split-by-side kept over pooled toward-chosen** — the symmetric traces demonstrate there's no
  side-bias artifact (a pooled plot would hide that).
- **pre-flight separated from zone 1** — "pre-flight call" means *before take-off*, not the approach
  zone; they overlap but aren't the same set.

## Status / caveats
- Not yet run end-to-end on real `.mat` data in-session — the first run should sanity-check call
  counts (esp. `n_preflight_calls`) and the degree ranges on the angle figure.
- Angle figure y-axis auto-scales; pin to ±90° if you want cross-session comparability.

## Broader project
Part of the **"Vicon & Avisoft analysis pipeline"** (temporal alignment of Vicon Nexus + Avisoft
recorders; one microcontroller TTL starts both; Vicon frame 1 = Avisoft sample 0). This file covers
the **beampattern figure stage** (`5_plot`) specifically.
