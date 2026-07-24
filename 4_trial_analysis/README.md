# Stage 4 — Trial analysis (behavioural metrics for stats)

Downstream of stage 3. Turns each fully-processed trial into **trial-level** and
**call-level** behavioural metrics and compiles them into two tidy study tables
for statistics. No new acoustics — it consumes what stages 1–3 already produced
plus the position-pipeline trajectory.

```
   …_mic_data_bp_proc.mat  (stages 1+3: proc.beam_aim_az_el_deg, bat_loc_at_call,
            │                mic_data.call, mic_data.call_idx_w_track, …)
            │      …_bat_pos.mat  (position pipeline: bat_pos, frame_rate, maze,
            │            │          perch_pos / tp_position / lp_position)
            ▼            ▼
   ┌───────────────────────────────────────────────┐
   │ 4  TRIAL ANALYSIS  (run_trial_analysis driver) │
   │  segment_flight        take-off / landing      │
   │  map_calls_to_frames   calls → Vicon frames    │
   │  extract_preflight_calls   pre-flight call table│
   │  classify_trial_outcome    landed? + side_first │
   │  compute_trial_metrics     one trial-master row │
   │  append_to_master_table    keyed upsert to CSV  │
   │  plot_beam_map / plot_preflight_beam   figures  │
   └───────────────────────────────────────────────┘
            │
            ▼   Stats/Beampattern_analysis/
                trial_master.csv (+.mat)      one row per trial
                preflight_calls.csv (+.mat)   one row per pre-flight call
                plots/                        optional figures
```

## What each analysis answers

| Ask | Function | Output |
|---|---|---|
| **1** pre-flight call → stats | `extract_preflight_calls` | one call row: beam az/el, speed at emission, time-before-take-off, goal-relative azimuth |
| **1a** call rate per trial | `compute_trial_metrics` | `call_rate_hz` (all with-track calls / tracked duration) **and** `preflight_call_rate_hz` (pre-flight calls / perch-sit time) |
| **1b** looking left vs right | `plot_beam_map` (default), `plot_preflight_beam` | top-down beam-ray map + decision-axis scan; az-el heatmap, landing-plane spotlight, goal-relative rose, azimuth-vs-time scan |
| **2** success + side chosen | `classify_trial_outcome` | `landed` and `side_first` (left/right) as **independent** columns, plus `end_zone`, `target_side`, `side_first_correct` |

## Key conventions

- **Frames vs samples.** Stage 1 aligns the audio and Vicon time axes at their
  END (`-fliplr(0:N-1)/fs`). `map_calls_to_frames` reproduces exactly that: a
  call at audio sample `loc` has time `t = -(nsamp - loc)/audio_fs (≤ 0)` and
  lands on frame `n_frames + frame_rate*t` (clamped to `[1, n_frames]`). It does
  **not** use `track.call_loc_idx_on_track_interp` (filled before later call
  filters, so it can be misaligned with `call_idx_w_track`).
- **Left / right = the stage-2 zones.** `left arm = zone 4 = +X = arm_purple`;
  `right arm = zone 5 = -X = arm_pink`. Reused verbatim via `build_maze_zones` +
  `select_mics_by_position` (stage 2).
- **Units / frame.** Trajectory, maze and perches are **mm** in the Vicon global
  frame; `proc.bat_loc_at_call` is **m** (×1000 to compare). `beam_aim_az_el_deg`
  is `cart2sph(mic − bat)` in the room frame (deg). The Vicon tail is trimmed to
  the first `vicon_dur_s` seconds (default 16) to match Avisoft.
- **Beam = head-aim proxy, not eye gaze.** Every "gaze/aim" figure is the sonar
  beam axis.

## Run

```matlab
setup_paths                          % stages 1–4 (and stage 2's zone code) on the path

cfg = struct();
cfg.bp_proc_file = 'Data/Beampattern_proc/batA125/beampattern_output/20260709_T06_mic_data_bp_proc.mat';
cfg.bat_pos_file = 'Analysis/position_processing/Bat_Position/batA125_20260709_06_bat_pos.mat';  % same trial
cfg.plot = true;
res = run_trial_analysis(cfg);       % appends both masters, makes figures
```

Batch: edit the `trials` list in `run_stage4_batch` and run it. Each call
upserts its rows (re-running a trial replaces, never duplicates — keyed on
`bat_id/session/trial`, and `+call_idx` for calls). After the loop it also draws
a pooled pre-flight figure across every trial written so far.

## Functions

### `run_trial_analysis(cfg) → res`
Driver for one trial. Loads the proc + bat_pos files, resolves perch positions
(priority `perch_pos` → `tp_position/lp_position` → `maze.takeoff_perch/landing_perch`;
explicit `cfg.seg_opts.tp_xyz/lp_xyz` wins), runs the whole chain, and appends
both masters. `res` = `struct(trial_row, preflight_calls, seg, outcome, cf)`.

Main `cfg` fields: `bp_proc_file` (required), `bat_pos_file` (required),
`out_root` (default `Stats/Beampattern_analysis`), `bat_id/session/trial/date`
(else parsed from the bat_pos filename), `seg_opts`, `outcome_opts`, `plot`
(default false), `plot_dir`, `vicon_dur_s` (default 16).

### `segment_flight(traj, frame_rate, maze[, opts]) → seg`
Geometry-only segmentation. `traj` is F×3 mm.

- **Take-off = speed-based:** first frame with `min_out_frames` (5) consecutive
  frames at speed ≥ `v_takeoff_mps` (0.5). The perch-sit is usually untracked, so
  take-off is *not* detected from leaving a region.
- **Landing = XY + speed:** first frame within `land_xy_mm` (250) of a landing
  perch AND at speed ≤ `land_v_mps` (0.5). No Z gate (the perch top sits below
  the tracked flight; the descent is untracked).

Other opts/defaults: `smooth_ms` 30, `v_rest_mps` 0.15, `land_window_s` 1.0.

`seg` fields: `t` (END-aligned, `t(end)=0`), `speed` (m/s), `dist_tp` (3D to
take-off marker), `dist_lp_xy` (horizontal to nearest landing perch),
`near_lp_id`, `min_dist_lp_xy_mm`, `tp_xyz` (1×3), `lp_xyz` (N×3),
`first_valid`, `last_valid`, `takeoff_frame`, `land_frame`, `land_perch_id`,
`takeoff_t`, `land_t`, `perch_sit_dur_s`, `flight_dur_s`, `params`.

### `map_calls_to_frames(bpp, frame_rate, n_frames[, seg]) → cf`
Places each with-track call (row-for-row with `proc.beam_aim_az_el_deg` and
`proc.bat_loc_at_call`) on the Vicon timeline. `cf` fields (nC×1): `call_idx`,
`loc`, `t`, `frame` (fractional), `speed_at_call`, `time_before_takeoff`
(`seg.takeoff_t − t`; >0 = before take-off). Needs `seg` for the last two.

### `extract_preflight_calls(bpp, seg, cf[, opts]) → pc` (table)
A call is pre-flight if its frame ≤ take-off frame (`preflight_time`) **or** the
bat was still within `perch_xy_mm` (300) of the take-off perch in XY
(`preflight_pos`); `is_preflight = OR`. Goal-relative azimuth = beam azimuth −
bearing(bat → landing perch #1), wrapped to ±180°; **>0 = aimed LEFT (+X / arm_purple)**.

`pc` columns: `call_row, call_idx, frame, t_s, time_before_takeoff_s,
speed_at_call_mps, on_perch, preflight_time, preflight_pos, is_preflight,
beam_az_deg, beam_el_deg, beam_sigma_deg, beam_method, beam_zone_id,
az_goal_rel_deg, dist_bat_to_LP_mm, batx_mm, baty_mm, batz_mm`. The driver
prepends `bat_id, session, trial, date`. (`on_perch` mirrors the `preflight_pos`
on-perch test.)

### `classify_trial_outcome(traj, frame_rate, maze, seg[, opts]) → out`
Two independent results:

- **`landed`** = the bat reached the landing zone during the trial
  (`~isnan(seg.land_frame)`; i.e. XY ≤ 250 mm of a perch AND speed ≤ 0.5 m/s).
  Touchdown is often untracked, so no separate at-rest re-test is applied.
- **`side_first`** = first arm (zone 4 = left / 5 = right) entered after take-off;
  falls back to X vs the wall-midline at closest approach.

`out` fields: `landed`, `landed_perch_id`, `end_dist_LP_mm`, `end_speed_mps`,
`min_dist_LP_xy_mm`, `end_zone_id`, `end_zone_name`, `side_first`,
`side_first_zone`, `side_first_frame`, `target_side` (arm the landing perch sits
on), `side_first_correct` (logical or NaN), `zones`.

### `compute_trial_metrics(keys, seg, cf, pc, outcome, frame_rate, n_frames) → trow`
Assembles the single trial-master row. Two call rates are reported because the
denominators answer different questions: `call_rate_hz` = all with-track calls /
tracked duration; `preflight_call_rate_hz` = pre-flight calls / perch-sit time.

**`trial_master` columns:**

| Group | Columns |
|---|---|
| keys | `bat_id, session, trial, date` |
| timing | `frame_rate, n_frames, trial_dur_s, takeoff_frame, land_frame, takeoff_t_s, land_t_s, perch_sit_dur_s, flight_dur_s` |
| outcome | `min_dist_LP_xy_mm, landed, end_dist_LP_mm, end_speed_mps, end_zone_id, end_zone_name, side_first, side_first_zone, side_first_frame, target_side, side_first_correct` |
| calls | `n_calls_w_track, n_preflight_calls, call_rate_hz, preflight_call_rate_hz` |
| pre-flight aim | `mean_preflight_az_deg, mean_preflight_el_deg, mean_preflight_az_goalrel_deg, frac_preflight_aim_left, mean_preflight_speed_mps` |

`side_first_correct` is tri-state encoded to survive CSV: **-1 = unknown, 0 = false, 1 = true**.
`frac_preflight_aim_left` = fraction of pre-flight calls with `az_goal_rel_deg > 0`.

### `append_to_master_table(new_rows, csv_path, key_vars) → T`
Idempotent keyed upsert: reads the existing CSV, unions columns, drops old rows
whose `key_vars` match a new row, appends, and writes both `csv_path` and the
sibling `.mat` (variable `T`). Keys: `{bat_id,session,trial}` for the trial
master, `{bat_id,session,trial,call_idx}` for the call master.

### `plot_beam_map(pc, outcome, seg[, opts]) → fig`
Recommended pre-flight plot. **Panel A:** take-off-centred top-down maze map
(+X = right arm, +Y = deeper) with walls, mics, take-off + all N landing perches,
the goal line, and one beam ray per call coloured by time-before-take-off.
**Panel B:** decision-axis scan vs time (x reversed). For ≥2 perches the axis is
`|off-to-perch2| − |off-to-perch1|` deg (>0 = aimed nearer landing 1); for a
single perch it degrades to signed goal-relative azimuth. Opts: `maze`, `mic_xy`
(mm), `mic_num`, `ray_len_mm` (400), `traj`, `save_dir`, `tag`, `visible`.

### `plot_preflight_beam(pc, outcome, seg[, opts]) → figs`
Four room-frame views: (1) az-el density heatmap, (2) landing-plane "spotlight"
(needs `seg` + `bat*_mm`), (3) polar rose of goal-relative azimuth, (4) azimuth
vs time-before-take-off. Panels are coloured by `side_first`/`landed` when a
pooled master table is passed. Opts: `save_dir`, `tag`, `az_bins` (36),
`el_bins` (18), `visible`. Because the maze is not axis-aligned, prefer
`plot_beam_map` for single trials and the goal-relative azimuth for pooling.

## Thresholds (tune once on 5–6 trials, then freeze)

| Function | Option | Default |
|---|---|---|
| `segment_flight` | `v_takeoff_mps` | 0.5 |
| `segment_flight` | `min_out_frames` | 5 |
| `segment_flight` | `land_xy_mm` | 250 (±25 cm) |
| `segment_flight` | `land_v_mps` | 0.5 |
| `segment_flight` | `smooth_ms` / `v_rest_mps` / `land_window_s` | 30 / 0.15 / 1.0 |
| `extract_preflight_calls` | `perch_xy_mm` | 300 |
| `classify_trial_outcome` | `land_window_s` (end-window medians) | from `seg.params` |

Landing = XY within `land_xy_mm` of a perch **and** speed ≤ `land_v_mps`; the Z
extent is intentionally not tested. Defaults are starting values — check them
against a few trials.

## Verify first

`selftest_stage4` runs segmentation + outcome on synthetic data with a known
answer (untracked perch-sit and touchdown, two landing perches, bat lands LEFT)
and prints `SELFTEST PASSED` on 7/7 checks. Run it before trusting real output.

## Depends on

`2_mic_zone_selection/build_maze_zones.m`, `select_mics_by_position.m` (zones);
a stage-3-completed `bp_proc` file (needs `proc.beam_aim_az_el_deg`); a
`bat_pos.mat` carrying `bat_pos`, `frame_rate`, `maze`, and perch positions
(`perch_pos` / `tp_position` / `lp_position`, or `maze.takeoff_perch` /
`maze.landing_perch`).

*Written by Rie Kaneko on 7/16/2026*
