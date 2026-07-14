# Stage 3 — Beam direction (marker-free head-aim proxy)

**Input:** a `bp_proc_file` (stage 1) + the candidate mic set per call (stage 2).
**Output, per call:** beam azimuth/elevation (the head-aim proxy), beam width,
and the loudest-mic direction for auditing — written back into the `bp_proc_file`.

---

## Files

| File | Role |
|---|---|
| `estimate_beam_direction.m` | Core estimator for a single call: samples → beam az/el + width. Marker-free. |
| `run_beamaim_maze.m` | Driver: `out = run_beamaim_maze(cfg)`. Loops over calls, applies stage-2 selection, calls the estimator, saves results. |
| `plot_beamaim_qc.m` | QC figure: top-view beam-aim arrows per call, coloured by method used. |
| `lib/` | `rbfcreate` / `rbfinterp` (radial-basis interpolation) and `gaussfit` (Gaussian fit). |

---

## The math / logic

For one call, stage 1 gives a level `L_m` (dB at the chosen frequency) for each
selected mic, and geometry gives the mic direction from the bat:

```
v_m = p_m − b ,   (az_m, el_m) = cart2sph(v_m)     % room frame, no head marker
```

So we have scattered samples `(az_m, el_m, L_m)` of the beam pattern. The beam
axis is where `L` is maximal. Four steps turn the scatter into a continuous
estimate:

**1. Peak mic (coarse).** The loudest mic gives a first, discrete direction
`(az*, el*)`. Robust but quantised to wherever a mic happens to sit.

**2. Interpolate.** Fit a smooth surface `L(az, el)` through the samples with a
radial-basis-function interpolant (`rbfcreate`/`rbfinterp`, multiquadric) and mask
it to the convex region the mics actually cover (no extrapolation beyond the data).

**3. Anchored peak (fine).** Search the interpolated surface for its maximum, but
**only within a window around the peak mic** `(az*, el*)`. This gives a continuous,
sub-mic-resolution direction while preventing the interpolant from jumping to a
spurious side-lobe far from any strong mic. The window half-size is
`opts.anchor_win_deg` (default 40°).

**4. Beam width.** Take the azimuth slice through the beam and fit a Gaussian
`L(az) ≈ A·exp(−(az − μ)² / 2σ²)` (`gaussfit`); `σ` is the beam half-width — a real
acoustic quantity, useful as QC.

**Why anchored, not the literal horizon slice.** The original `beam_aim.m` reads
azimuth off the `el ≈ 0` slice and is checked call-by-call in a GUI. Run
unattended, that slice is fragile: when the mics don't straddle the bat's horizon
the interpolant extrapolates at the sampled-region edge and returns azimuths tens
to hundreds of degrees off (verified on lab data: jumps to +80° where the true
peak was −160°). Anchoring to the loudest mic removes that failure mode. Set
`opts.method = 'midline'` to reproduce the original behaviour, or `'peak2d'` for an
unconstrained interpolated peak.

**Fallback.** The interpolation needs several mics spanning the beam. If a call
has fewer than `opts.min_mics_fit` (default 5) in-view mics, or the fit is
unusable, the estimator returns the **peak-mic** direction and flags it
(`method = 2`). The peak-mic direction is always saved too, so every call can be
audited and the two methods compared.

---

## Output fields (written into the `bp_proc_file`)

| Field | Meaning |
|---|---|
| `proc.beam_aim_az_el_deg` | head-aim proxy azimuth/elevation (deg) |
| `proc.beam_aim_sigma_deg` | azimuth beam half-width (deg) |
| `proc.beam_aim_method` | 1 = interp, 2 = peak fallback, 0 = none |
| `proc.beam_peak_az_el_deg` | loudest-mic direction (audit / fallback) |
| `proc.beam_zone_id`, `beam_sel_mic_num`, `beam_n_mics_used` | per-call audit |

## `cfg` fields

`bp_proc_file` (required), `bat_pos_file`, `freq_desired` (kHz), `sync_offset_s`
(Vicon↔Avisoft offset — the alignment plug-in point), `save_back`, `est_opts`.
See the `run_beamaim_maze.m` header.

.
