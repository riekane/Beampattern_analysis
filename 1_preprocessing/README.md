# Stage 1 — Preprocessing (raw → calibrated per-call levels)

**Input:** raw multichannel Avisoft audio, the Vicon trajectory, mic positions,
and the call-detection output.
**Output:** a `bp_proc_file` (`…_mic_data_bp_proc.mat`) holding, for every
detected call, the received level at every mic as a function of frequency —
corrected so levels are comparable across mics — plus take-off-centred copies of
all plotted geometry. This is the file stages 2–3 consume.

This stage reproduces the lab's `bp_proc.m` non-interactively for this rig: no
GUI/`uigetfile`, reads this project's own file formats, and (until measured mic
calibration exists) treats the array as uniform Knowles FG capsules.

---

## Files

| File | Role |
|---|---|
| `bp_proc_vicon.m` | The stage function: `data = bp_proc_vicon(cfg)`. Loads inputs, builds the marker-free track, runs the DSP in `lib/`, adds take-off-centred coords, writes the `bp_proc_file`. |
| `run_bp_proc_vicon.m` | Thin CONFIG-block script wrapper (edit paths, run). |
| `lib/` | Reused signal-processing helpers, the take-off-frame helpers, and `parameters_beam_pattern.mat` (defaults). Self-contained; added to the path automatically. |

---

## The math / logic

For each detected call the goal is a per-mic, per-frequency **source-referenced
level** `L_m(f)`, referenced to a fixed distance `d0 = 0.1 m` from the bat.

**1. Call emission time & geometry.** A call detected at a mic was emitted
earlier, by the travel time `‖p_m − b‖ / c`, where `c` is the speed of sound in
humid air (`air_absorption_vec`). Solving this places the call on the
trajectory, giving the bat position `b` at emission and the bat→mic distance
`d_m = ‖p_m − b‖`.

**2. Extract & align.** A short window around the call is cut from every channel
and aligned by expected arrival time, so the same emission is compared across
mics (`get_time_series_around_call_fcn`).

**3. Spectrum.** Each windowed call is tapered (Tukey) and transformed to a
power spectrum (`2·|FFT|²/(N·fs)`, plus 1/3-octave-band RMS) → a raw level
`L_m^raw(f)` in dB (`get_call_fcn`). Magnitude only, so microphone polarity is
irrelevant. Here `dura_flag = 1`, so the call_detect start/end marks define the
call; a template from the marked channel is cross-correlated across channels to
carve the call from each mic.

**4. Transmission-loss compensation** (`compensate_call_dB_fcn`). Refer the
received level back to `d0`:

```
L_m^raw(f)                                   raw PSD level, dB
TL_m(f) = 20·log10(d_m/d0)                   spherical spreading (d0 = 0.1 m)
        + α(f,T,H)·(d_m − d0)                air absorption, dB/m (Bass)

L_comp(f)     = L_m^raw + TL_m − sens(f) − bp(θ_m,f)          → call_psd_dB_comp_withbp
L_re20uPa(f)  = L_comp + 20·log10(1/20e-6) − gain_m           → call_psd_dB_comp_re20uPa_withbp
```

`α` and `c` come from `air_absorption_vec(f,T,H)` (Bass formula). The
**distance-dependent** term `TL_m(f)` is what makes levels comparable across
mics — a mic close to the bat is no longer "louder" merely for being close. The
`20·log10(1/20e-6)` term expresses the result as SPL re 20 µPa.

**5. Microphone terms — sensitivity `sens(f)`, directivity `bp(θ,f)`, gain.**
These describe the *microphone*, not the bat. With no measured calibration all
mics are treated as identical Knowles FG capsules: `sens` flat, `bp ≡ 0`
(omnidirectional), `gain` equal. Being identical across mics, they **cancel when
comparing directions** — so beam direction is unaffected; only the absolute SPL
scale is left uncalibrated. Supply `cfg.mic_sens_file` / `cfg.mic_bp_file` later
to replace this assumption (they may be full-array or per-recorded-channel; the
recorded channels are auto-subset).

**Marker-free head aim.** The input is the bat's position track (bat marker 1 —
the head / emission point, carrying no head-orientation information), so head aim
is seeded from the smoothed track velocity (`head_aim_prescribed = 0`) and the
head normal is the prescribed `cfg.head_normal`. This only feeds `bp_proc`'s internal bookkeeping;
the beam-based proxy in stage 3 replaces it, so its accuracy does not affect the
result.

**Channel ↔ mic mapping.** The rig numbers 31 physical mics `1..29, 31, 32`
(there is **no Mic_30**), and records the first N in that order. Recording
channel `k` is mapped to the mic whose parsed number equals `canon(k)`, where
`canon = [1:29, 31, 32]` — **not** to the k-th row of the position file. A mic
missing from the position file that day leaves a NaN row for *its own* channel
instead of shifting every later channel. Override with `cfg.mic_channels` if the
wiring ever differs.

**Take-off-centred coordinates.** After the DSP, `add_takeoff_centered_coords`
adds `data.takeoff_centered` — shifted copies of every plotted location/vector
in a frame where the take-off perch is the origin and the maze extends toward
+Y. Raw fields are untouched (see `lib/README.md`).

---

## `cfg` (see `bp_proc_vicon.m` / `run_bp_proc_vicon.m` for the full list)

| Field | Meaning |
|---|---|
| `combined_file` | Raw multichannel Avisoft recording (`sig`, `fs`). |
| `detected_file` | call_detect output (`call` struct, `num_ch_in_file`, `fs`, `meta`). |
| `bat_pos_file` | Vicon bat track (`bat_pos` N×3, `frame_rate`, `maze`, perch positions). |
| `mic_pos_file` | Mic layout (`mic_loc`, `mic_vec`/`mic_pointing_direction`, `mic_names`). |
| `tempC`, `humid` | Environment; leave `[]` to auto-pull `meta.temperature_C/humidity_pct`. |
| `pos_units` | `'mm'` or `'m'` (converted to metres). |
| `axis_orient` | Column permutation to `[x y z]` Vicon-global (`[1 2 3]` = as-is). |
| `head_normal` | Prescribed head-normal for the 1-marker track (e.g. `[0 0 1]`). |
| `vicon_dur_s` | Vicon-track keep length in s (default 16) to match Avisoft; `Inf` disables. |
| `mic_channels` | Optional explicit channel→mic-row map. |
| `mic_sens_file`, `mic_bp_file`, `mic_sens_dB` | Optional measured calibration (else uniform Knowles FG). |
| `params_file`, `preprocessing_dir` | Optional overrides; default to `lib/`. |
| `out_dir` / `out_root`, `bat_id`, `out_name` | Output location (see below). |

### Usage

```matlab
cfg = struct();
cfg.combined_file = 'Analysis/.../Combined_trial_data/T0000016_combined.mat';
cfg.detected_file = 'Analysis/.../batA125/done/20260625_T0000008_detected.mat';
cfg.bat_pos_file  = 'Analysis/position_processing/Bat_Position/batA125_20260706_16_bat_pos.mat';
cfg.mic_pos_file  = 'Analysis/position_processing/Mic_positions/mic_pos_20260706.mat';
cfg.tempC = []; cfg.humid = [];          % auto from detected meta
cfg.pos_units = 'mm'; cfg.axis_orient = [1 2 3]; cfg.head_normal = [0 0 1];
data = bp_proc_vicon(cfg);
```

---

## Output layout

If `cfg.out_dir` is set it is used as the bat folder as-is. Otherwise the file
is written under a per-bat folder inside a processed-data root:

```
Data/Beampattern_proc/<batID>/beampattern_output/<out_name>_mic_data_bp_proc.mat
Data/Beampattern_proc/<batID>/plot/                (QC figures; data.plot_dir)
```

`batID` comes from `cfg.bat_id`, else the first token of the `bat_pos_file`
name (e.g. `batA125_20260709_06_bat_pos.mat` → `batA125`). `out_name` defaults
to a value derived from the detected filename. The struct is saved with
`-struct … -v7.3`; `data.saved_file` and `data.plot_dir` record where things
went.

## Key `bp_proc_file` fields (consumed downstream)

| Field | Meaning |
|---|---|
| `proc.call_psd_dB_comp_re20uPa_withbp` | Compensated per-call, per-mic level (cells). |
| `proc.call_freq_vec` | Frequency axis per call/mic (Hz). |
| `proc.bat_loc_at_call` | Bat position per call (m), room frame. |
| `mic_loc`, `mic_names` | Mic positions (m, one row per recorded channel) and labels. |
| `mic_data.call_idx_w_track` | Indices of detected calls that fall on the track. |
| `takeoff_centered.*` | Take-off-centred copies for plotting (raw fields untouched). |

*Updated by Rie Kaneko on 7/23/2026*
