# Beam-pattern analysis — big brown bat, Vicon + Avisoft

Estimate, for every echolocation call a big brown bat (*Eptesicus fuscus*) emits
in flight, **which way its sonar beam points** (azimuth and elevation) and **how
wide the beam is** — using a wall-mounted microphone array and Vicon motion
capture of the bat's position — and then turn those per-call beam directions into
**per-trial behavioural metrics** for a two-arm (Y-maze) decision task.

The bat's head **aim direction** is not directly measured. It wears a small
marker set, and its head / sound-emission point (bat marker 1) is recovered by
`position_processing` — observed when visible, otherwise reconstructed from the
other markers' rigid geometry — but that yields the emission *position*, not
which way the head points. Beam direction is instead recovered **from the sound
itself**: after correcting each mic's received level for propagation, the
direction in which the emitted energy is greatest is the beam axis. Because that
axis is where a bat usually points its head, it doubles as a head-aim proxy —
with the caveat below.

---

## What you need (inputs)

All four inputs come from one trial, produced by the upstream tools:

| Input | Produced by | Key contents |
|---|---|---|
| `T…_combined.mat` | recording rig | `sig` (samples × channels raw audio), `fs` |
| `…_detected.mat` | `call_detect` | `call` struct (`locs`, `call_start_idx`, `call_end_idx`, `channel_marked`), `fs`, `num_ch_in_file`, `meta.temperature_C`, `meta.humidity_pct` |
| `…_bat_pos.mat` | `position_processing` | `bat_pos` (bat marker 1 = head/emission point, frames × 3, mm), `frame_rate`, `maze` landmark struct, perch positions |
| `mic_pos_….mat` | `position_processing` | `mic_loc` (mics × 3, mm), `mic_vec`, `mic_names` |

**Convention that must hold:** recording channel *j* corresponds to `mic_loc`
row *j* corresponds to `mic_names{j}`. Channels are mapped to physical mics by
number (`canon = [1:29, 31, 32]`, no Mic_30); a mic missing from the position
file leaves a NaN row for its own channel rather than shifting later channels.

## What you get (output)

A processed file `…_mic_data_bp_proc.mat`. After the full run it holds, per call:

| Field | Meaning |
|---|---|
| `proc.beam_aim_az_el_deg` | beam azimuth / elevation (deg, room frame) — the head-aim proxy |
| `proc.beam_aim_sigma_deg` | azimuth beam half-width (deg) |
| `proc.beam_aim_method` | 1 = interpolated, 2 = peak-mic fallback, 0 = none |
| `proc.beam_peak_az_el_deg` | loudest-mic direction (audit / fallback) |
| `proc.beam_zone_id`, `proc.beam_sel_mic_num`, `proc.beam_n_mics_used` | per-call audit |
| `proc.call_psd_dB_comp_re20uPa_withbp`, `proc.call_freq_vec`, `proc.bat_loc_at_call` | per-call compensated levels, frequency axis, and emission position (from stage 1) |
| `takeoff_centered.*` | take-off-centred copies of all plotted geometry (raw fields untouched) |

Stage 4 additionally writes two tidy study tables (`trial_master`,
`preflight_calls`) for statistics, and stage 5 builds the figures and a SQLite
database of every trial and call.

---

## The pipeline

```
   raw audio (Avisoft)          bat trajectory + mic positions (Vicon)
          │                                  │
          ▼                                  │
   ┌──────────────────┐                      │
   │ 1  PREPROCESSING │  extract each call, correct for propagation
   │  bp_proc_vicon   │  → calibrated received level (dB) at every mic
   └──────────────────┘
          │  …_mic_data_bp_proc.mat
          ▼
   ┌──────────────────┐
   │ 2  MIC SELECTION │  per call, keep only the mics that can actually
   │  (maze zones)    │  "see" the bat (occluder-aware)
   └──────────────────┘
          │  candidate mic set per call
          ▼
   ┌──────────────────┐
   │ 3  BEAM DIRECTION│  interpolate the beam over the sphere, find its
   │  (head proxy)    │  peak → beam azimuth/elevation + beam width
   └──────────────────┘
          │  beam_aim_az_el_deg, beam_aim_sigma_deg, … per call
          ▼
   ┌──────────────────┐
   │ 4  TRIAL ANALYSIS│  segment flight, map calls to frames, classify
   │  (behaviour)     │  outcome/side → per-trial + per-call tables
   └──────────────────┘
          │  trial_master.csv, preflight_calls.csv
          ▼
   ┌──────────────────┐
   │ 5  PLOT (Python) │  read bp_proc (v7.3), build figures + SQLite DB
   └──────────────────┘
```

| Folder | Stage | What it computes |
|---|---|---|
| [`1_preprocessing/`](1_preprocessing/README.md) | raw → calibrated levels | call extraction, spectra, transmission-loss compensation |
 [`2_mic_zone_selection/`](2_mic_zone_selection/README.md) | occluder-aware mic set | line-of-sight: keep mics whose path to the bat isn't blocked by a wall (maze zones become a trial-level region label) 
| [`3_beam_direction/`](3_beam_direction/README.md) | beam-aim proxy | interpolate beam, anchored peak, beam width |
| [`4_trial_analysis/`](4_trial_analysis/README.md) | behavioural metrics | flight segmentation, calls→frames, outcome/side, tidy tables |
| [`5_plot/`](5_plot/README_bp_figure_pipeline.md) | figures + database | Python: read bp_proc, junction/call-rate figures, SQLite + CSV |

Each stage folder has its own README with the detailed math. Stages 1 and 3 have
a `lib/` of reused signal-processing / interpolation helpers. Supporting folders:
`docs/` (geometry figures) and `archive/` (superseded code).

---

## The core idea

**Beam direction from the array.** For one call, each microphone *m* sits at a
known position `p_m` and the bat is at `b`. The direction from the bat to that
mic, in the room frame, is

```
v_m = p_m − b ,     (az_m, el_m) = cart2sph(v_m)
```

Each mic also records a received level `L_m` (dB). Plotting `L_m` against
`(az_m, el_m)` samples the bat's beam pattern from the bat's own viewpoint. The direction of maximum `L` is the beam axis. Stage 3
turns the scattered `(az_m, el_m, L_m)` samples into a continuous estimate
(interpolation + fit) and also reports the beam half-width.

**Why the first two stages exist.** The direction estimate is only as good as the
levels `L_m` and the mics that contribute them. Stage 1 makes `L_m` comparable
across mics by removing propagation effects (a near mic is not "louder" just for
being close). Stage 2 drops mics whose line of sight to the bat is blocked by the
occluder, which would otherwise pull the interpolated peak toward a wall.

**Transmission-loss compensation (stage 1).** Each received level is referenced
back to a fixed distance `d₀ = 0.1 m` from the bat:

```
L_m(f) = L_m^raw(f) + 20·log10(d_m/d₀) + α(f,T,H)·(d_m − d₀) − (mic terms)
```

The first added term is spherical spreading, the second is atmospheric
absorption (`α` from the Bass / ISO 9613 model, using the trial's temperature and
humidity). The **distance-dependent** terms are what make levels comparable
across mics.

---

## How to run

```matlab
setup_paths            % once per MATLAB session: adds stage folders 1–4 to the path
```

Then run the Live Script **`beam_pattern_trial_pipeline.mlx` (per-trial)** section by section, or
call the stage functions directly:

```matlab
% Stage 1 — edit the CONFIG block in run_bp_proc_vicon.m to point at ONE trial's
% four input files, then run it. It writes …_mic_data_bp_proc.mat.
data = bp_proc_vicon(cfg);

% Stages 2+3 — beam direction per call, written back into the bp_proc file.
out  = run_beamaim_maze(struct('bp_proc_file', bp_proc_file, ...
                               'bat_pos_file', bat_pos_file));

% Stage 4 — per-trial behavioural metrics + tidy tables.
res  = run_trial_analysis(struct('bp_proc_file', bp_proc_file, ...
                                 'bat_pos_file', bat_pos_file, 'plot', true));

% QC
plot_mic_zone_selection_qc(bat_pos_file, mic_pos_file);   % check the zoning geometry
plot_beamaim_qc(bp_proc_file, out);                  % check the beam-aim arrows
```

To run a whole session at once, use the session-level drivers
(`beam_pipeline_session.mlx` for stages 1–3 across every trial in one
`batID + date`, and `run_stage4_batch` for the stage-4 tables); the per-trial
Live Scripts (`beam_pipeline_one_trial.mlx`, `trial_analysis_session.mlx`) show
the same steps interactively. Stage 5 is Python — see
[`5_plot/README_bp_figure_pipeline.md`](5_plot/README_bp_figure_pipeline.md).

`cfg` and the stage options are documented in the function headers and each
stage README. **All four stage-1 inputs must be from the same trial.**

---

## Notes

- Reused signal-processing helpers live in each stage's `lib/` and are
  third-party or previously validated code (atmospheric absorption, radial-basis
  interpolation, Gaussian fit); the pipeline is otherwise self-contained.
- Stages 1–4 are MATLAB; stage 5 is pure Python (no MATLAB runtime needed — it
  reads the v7.3/HDF5 `bp_proc` files directly).

---

## License

Licensed under the **Apache License 2.0** — see [`LICENSE.txt`](LICENSE.txt).

This repository bundles third-party code, retained with its original authorship
in the source-file headers:

- the beam-pattern processing toolbox by **Wu-Jung Lee**
  (`github.com/leewujung/beampattern_processing`, Apache-2.0) — the per-call
  extraction, spectra, and transmission-loss compensation in `1_preprocessing/lib/`,
  and the `bp_proc` step that `bp_proc_vicon.m` reimplements;
- radial-basis-function interpolation (`rbfcreate` / `rbfinterp`, A. Chirokov,
  MATLAB File Exchange);
- Gaussian fitting (`gaussfit`, MATLAB File Exchange);
- an atmospheric-absorption routine (`air_absorption_vec`, redistributed with the
  toolbox above).

Written by Rie Kaneko on 7/14/2026
