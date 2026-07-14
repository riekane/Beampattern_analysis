# Beam-pattern analysis — big brown bat, Vicon + Avisoft

Estimate, for every echolocation call a big brown bat (*Eptesicus fuscus*) emits
in flight, **which way its sonar beam points** (azimuth and elevation) and **how
wide the beam is** — using a wall-mounted microphone array and Vicon motion
capture of the bat's position.

The bat carries a single body marker, so its head is not tracked. Beam direction
is instead recovered **from the sound itself**: after correcting each mic's
received level for propagation, the direction in which the emitted energy is
greatest is the beam axis. Because that axis is where a bat usually points its
head, it doubles as a head-aim proxy — with the caveat below.

---

## What you need (inputs)

All four inputs come from one trial, produced by the upstream tools:

| Input | Produced by | Key contents |
|---|---|---|
| `T…_combined.mat` | recording rig | `sig` (samples × channels raw audio), `fs` |
| `…_detected.mat` | `call_detect` | `call` struct (`locs`, `call_start_idx`, `call_end_idx`, `channel_marked`), `fs`, `num_ch_in_file`, `meta.temperature_C`, `meta.humidity_pct` |
| `…_bat_pos.mat` | `position_processing` | `bat_pos` (frames × 3, mm), `frame_rate`, `maze` landmark struct |
| `mic_pos_….mat` | `position_processing` | `mic_loc` (mics × 3, mm), `mic_vec`, `mic_names` |

**Convention that must hold:** recording channel *j* corresponds to `mic_loc`
row *j* corresponds to `mic_names{j}`. The number of recorded channels must equal
the number of positioned mics for the trial. (The count is checked at run time;
the ordering is assumed.)

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

---

## The three stages

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
          │
          ▼   beam_aim_az_el_deg, beam_aim_sigma_deg, … per call
```

| Folder | Stage | What it computes |
|---|---|---|
| [`1_preprocessing/`](1_preprocessing/README.md) | raw → calibrated levels | call extraction, spectra, transmission-loss compensation |
| [`2_mic_selection/`](2_mic_selection/README.md) | occluder-aware mic set | classify bat position → allowed microphones |
| [`3_beam_direction/`](3_beam_direction/README.md) | beam-aim proxy | interpolate beam, anchored peak, beam width |

Each stage folder has its own README with the detailed math. Supporting folders:
`docs/` (geometry figures), `archive/` (superseded code), and a `lib/` inside
stages 1 and 3 holding the reused signal-processing / interpolation helpers.

---

## The core idea

**Beam direction from the array.** For one call, each microphone *m* sits at a
known position `p_m` and the bat is at `b`. The direction from the bat to that
mic, in the room frame, is

```
v_m = p_m − b ,     (az_m, el_m) = cart2sph(v_m)
```

Each mic also records a received level `L_m` (dB). Plotting `L_m` against
`(az_m, el_m)` samples the bat's beam pattern from the bat's own viewpoint, with
no head frame required. The direction of maximum `L` is the beam axis. Stage 3
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
setup_paths            % once per MATLAB session: adds the stage folders to path
```

Then run the Live Script **`beam_pattern_pipeline.mlx`** section by section, or
call the stage functions directly:

```matlab
% Stage 1 — edit the CONFIG block in run_bp_proc_vicon.m to point at ONE trial's
% four input files, then run it. It writes …_mic_data_bp_proc.mat.
data = bp_proc_vicon(cfg);

% Stages 2+3 — beam direction per call, written back into the bp_proc file.
out  = run_beamaim_maze(struct('bp_proc_file', bp_proc_file, ...
                               'bat_pos_file', bat_pos_file));

% QC
plot_mic_selection_qc(bat_pos_file, mic_pos_file);   % check the zoning geometry
plot_beamaim_qc(bp_proc_file, out);                  % check the beam-aim arrows
```

`cfg` and the stage-3 options are documented in the function headers and each
stage README. **All four stage-1 inputs must be from the same trial.**

---


## Notes

- Reused signal-processing helpers live in each stage's `lib/` and are
  third-party or previously validated code (atmospheric absorption, radial-basis
  interpolation, Gaussian fit); the pipeline is otherwise self-contained.
