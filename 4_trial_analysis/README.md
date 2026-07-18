# Stage 4 — Trial analysis (behavioural metrics for stats)

Downstream of stage 3. Turns each fully-processed trial into **trial-level and
call-level behavioural metrics** and compiles them into two tidy study tables
for statistics. No new acoustics — it consumes what stages 1–3 already produced
plus the position-pipeline trajectory.

```
   …_mic_data_bp_proc.mat  (stages 1+3: proc.beam_aim_az_el_deg, bat_loc_at_call,
            │                track.*, mic_data.call, …)
            │      …_bat_pos.mat  (position pipeline: bat_pos, frame_rate, maze,
            │            │          maze.takeoff_perch / maze.landing_perch)
            ▼            ▼
   ┌─────────────────────────────┐
   │ 4  TRIAL ANALYSIS           │
   │  segment_flight  (shared)   │  speed(t), take-off frame, landing frame
   │   ├ extract_preflight_calls │  1  pre-flight calls  (+ 1a call rate)
   │   ├ classify_trial_outcome  │  2  landed? + side_first (left/right)
   │   └ plot_preflight_beam     │  1b beam-aim heatmap / spotlight / rose / scan
   └─────────────────────────────┘
            │
            ▼   Z:\Rie\Stats\Beampattern_analysis\
                trial_master.csv (+.mat)     one row per trial
                preflight_calls.csv (+.mat)  one row per pre-flight call
                plots\                        optional figures
```

## What each thing answers

| Your ask | Function | Output |
|---|---|---|
| **1** pre-flight call → stats | `extract_preflight_calls` | one call-table row per pre-flight call: beam az/el, **speed at emission**, time-before-take-off, goal-relative azimuth, PSD hooks |
| **1a** call rate per trial | `compute_trial_metrics` | `call_rate_hz` (all calls / trial) **and** `preflight_call_rate_hz` (pre-flight calls / perch-sit time) |
| **1b** looking left vs right | `plot_preflight_beam` | az-el heatmap (default), landing-plane "spotlight", goal-relative rose, azimuth-vs-time scan; faceted by outcome when pooled |
| **2** success + side | `classify_trial_outcome` | `landed` (bool) and `side_first` (left/right) as **independent** columns, plus `end_zone`, `target_side`, `side_first_correct` |

## Key conventions (verified against stages 1–3)

- **Frames vs samples.** Stage 1 aligns the audio and Vicon time axes at their
  END (`-fliplr(0:N-1)/fs`). `map_calls_to_frames` reproduces exactly that, so a
  call's frame is `n_frames + frame_rate*t`. It does **not** use
  `track.call_loc_idx_on_track_interp` (filled before later call filters, so it
  can be misaligned with `call_idx_w_track`).
- **Left / right = the stage-2 zones.** `left arm = zone 4 = +X = arm_purple`
  (`maze_exit_left`); `right arm = zone 5 = -X = arm_pink` (`maze_exit_right`).
  Reused verbatim via `build_maze_zones` + `select_mics_by_position`.
- **Units / frame.** Trajectory, maze and perches are **mm** in the Vicon global
  frame; `proc.bat_loc_at_call` is **m** (×1000 to compare). `beam_aim_az_el_deg`
  is `cart2sph(mic−bat)` in the room frame (deg). Assumes stage-1
  `axis_orient = [1 2 3]` (same assumption `run_beamaim_maze` makes).
- **Beam = head-aim proxy, not eye gaze.** Every "gaze/aim" figure is the sonar
  beam axis.

## Run

```matlab
setup_paths                          % stage folders on the path
addpath('4_trial_analysis')          % (until setup_paths is updated to include it)

cfg = struct();
cfg.bp_proc_file = 'Z:\Rie\Data\Beampattern_proc\batA125\beampattern_output\20260709_T06_mic_data_bp_proc.mat';
cfg.bat_pos_file = 'Z:\...\batA125_20260709_06_bat_pos.mat';   % same trial
cfg.plot = true;
res = run_trial_analysis(cfg);       % appends to the two masters, makes figures
```

Batch: loop `run_trial_analysis` over your trials; each call upserts its rows
(re-running a trial replaces, never duplicates — keyed on bat_id/session/trial).

## Thresholds (tune once on 5–6 trials, then freeze)

`segment_flight`/`classify_trial_outcome` opts: `perch_radius_mm` (200),
`v_takeoff_mps` (0.5), `v_rest_mps` (0.15, allows crawling), `land_window_s`
(1.0), `success_radius_mm` (150 = within 15 cm of the LP marker). Defaults are
starting values — check them against a few trials.

## Verify first

`selftest_stage4` runs the whole chain on synthetic data with a known answer
(bat lands left) and prints PASS/FAIL. Run it before trusting real output.

## Depends on

`2_mic_selection/build_maze_zones.m`, `select_mics_by_position.m` (zones);
a stage-3-completed `bp_proc` file (needs `proc.beam_aim_az_el_deg`); a
`bat_pos.mat` whose `maze` carries `takeoff_perch` and `landing_perch`.
