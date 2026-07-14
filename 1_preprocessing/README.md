# Stage 1 — Preprocessing (raw → calibrated per-call levels)

**Input:** raw multichannel audio, the Vicon trajectory, mic positions, and the
call-detection output.
**Output:** a `bp_proc_file` (`…_mic_data_bp_proc.mat`) holding, for every call,
the received level at every mic as a function of frequency — corrected so that
levels are comparable across mics. This is the file stages 2–3 consume.

This stage reproduces the lab's `bp_proc.m` non-interactively for this rig.

---

## Files

| File | Role |
|---|---|
| `bp_proc_vicon.m` | The stage function: `data = bp_proc_vicon(cfg)`. Loads inputs, builds the marker-free track, calls the DSP in `lib/`, writes the `bp_proc_file`. |
| `run_bp_proc_vicon.m` | Thin CONFIG-block script wrapper (for running outside the Live Script). |
| `lib/` | Reused signal-processing helpers + `parameters_beam_pattern.mat` (defaults). Self-contained. |

---

## The math / logic

For each detected call the goal is a per-mic, per-frequency **source-referenced
level** `L_m(f)`.

**1. Call emission time & geometry.** A call detected at a mic was emitted
earlier, by the travel time `‖p_m − b‖ / c`, where `c` is the speed of sound in
humid air. Solving this places the call on the trajectory and gives the bat
position `b` at emission and the bat→mic distance `d_m = ‖p_m − b‖`.

**2. Extract & align.** A short window around the call is cut from every channel
and aligned by expected arrival time, so the same emission is compared across
mics (`get_time_series_around_call_fcn`).

**3. Spectrum.** Each windowed call is transformed to a power spectrum
(`|FFT|²`, and 1/3-octave-band RMS) → a raw level `L_m^raw(f)` in dB
(`get_call_fcn`). Magnitude only, so microphone polarity is irrelevant.

**4. Transmission-loss compensation** (`compensate_call_dB_fcn`). Convert the
received level back to a fixed reference distance `d₀` from the bat:

```
L_m(f) = L_m^raw(f) + TL_m(f)   − sens(f) − bp(θ_m,f) − gain_m
TL_m(f) = 20·log10(d_m/d₀)          (spreading loss)
        + α(f,T,H)·(d_m − d₀)        (air absorption, dB/m; ISO 9613 / Bass)
```

`α` and `c` come from `air_absorption_vec(f,T,H)`. The **distance-dependent** term
`TL_m(f)` is what makes levels comparable across mics — a mic close to the bat is
no longer "louder" merely for being close.

**5. Microphone terms — sensitivity `sens(f)`, directivity `bp(θ,f)`, gain.**
These describe the *microphone*, not the bat. With no measured calibration all
mics are treated as identical Knowles FG capsules: `sens` flat, `bp ≡ 0`
(omnidirectional), `gain` equal. Being identical across mics, they **cancel when
comparing directions** — so beam direction is unaffected; only the absolute SPL
scale is left uncalibrated. Supply `cfg.mic_sens_file` / `cfg.mic_bp_file` later
to replace this assumption.

---

## `cfg` (see `bp_proc_vicon.m` header for the full list)

Trial files (`combined_file`, `detected_file`, `bat_pos_file`, `mic_pos_file`),
environment (`tempC`, `humid` — leave `[]` to auto-pull from the detected file's
metadata), geometry (`pos_units`, `axis_orient`), and optional calibration files.
The DSP helpers and parameters template are auto-located in `lib/`.

## Key `bp_proc_file` fields (consumed downstream)

`proc.call_psd_dB_comp_re20uPa_withbp` (compensated level), `proc.call_freq_vec`,
`proc.bat_loc_at_call` (bat position per call, m), `mic_loc`, `mic_names`,
`mic_data.call_idx_w_track`.


