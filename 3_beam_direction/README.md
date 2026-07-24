# Stage 3 — Beam direction (marker-free head-aim proxy)

**Input:** a processed beam file `bp_proc_file` (stage 1) plus the maze-aware
candidate mic set per call (stage 2).
**Output, per call:** beam azimuth/elevation (the head-aim proxy), beam width,
and the loudest-mic direction for auditing — written back into the `bp_proc_file`.

This stage lives at `Analysis/Beampattern_analysis/3_beam_direction/`.

---

## Files

| File | Role |
|---|---|
| `estimate_beam_direction.m` | Core estimator for a single call: scattered mic samples → beam az/el + width. Marker-free. |
| `run_beamaim_maze.m` | Driver `out = run_beamaim_maze(cfg)`. Loops over calls, applies stage-2 mic selection, calls the estimator, saves results. |
| `plot_beamaim_qc.m` | QC figure: top-view beam-aim arrows per call, coloured by the method used. |
| `lib/` | `rbfcreate` / `rbfinterp` (radial-basis interpolation) and `gaussfit` (Gaussian fit). See `lib/README.md`. |

---

## The concept


For one call, stage 1 gives a received level `L_m` (dB at the chosen frequency)
for each selected mic, and geometry gives the mic direction from the bat, in the
room (Vicon-global) frame:

```
v_m = p_m − b ,   [az_m, el_m] = cart2sph(v_m)     % no head marker needed
```

So we have scattered samples `(az_m, el_m, L_m)` of the beam pattern. The beam
axis is where `L` is maximal. The estimator turns the scatter into a continuous
estimate:

**1. Peak mic (coarse).** The loudest mic gives a first, discrete direction
`(az*, el*)`. Robust, but quantised to wherever a mic happens to sit. It is
**always** computed and returned, so every call can be audited.

**2. Azimuth recentring.** `cart2sph` returns azimuth in `(−π, π]`. If the in-view
mics straddle the ±180° seam (bat pointing roughly toward −x), a linear grid or
convex mask would treat neighbouring mics as ~360° apart. The samples are first
shifted onto the **circular mean** of the mic azimuths so they are contiguous,
then the result is mapped back at the end.

**3. Interpolate.** Fit a smooth surface `L(az, el)` through the samples with a
radial-basis-function interpolant (`rbfcreate`/`rbfinterp`) and **mask it to the
convex hull the mics actually cover** (`boundary`/`inpolygon`) — no extrapolation
beyond the data. `interp_method='rb_natural'` uses `griddata(...,'natural')`
instead.

**4. Anchored peak (fine).** Search the interpolated surface for its maximum, but
**only within a window around the peak mic** `(az*, el*)`. This yields a
continuous, sub-mic-resolution direction while preventing the interpolant from
jumping to a spurious side-lobe far from any strong mic. The window half-size is
`anchor_win_deg` (default 40°).

**5. Beam width.** Take the azimuth slice through the beam elevation and fit a
Gaussian `L(az) ≈ A·exp(−(az − μ)² / 2σ²)` (`gaussfit`). `σ` is the beam
half-width in azimuth — a real acoustic quantity, useful as QC. Non-converged or
implausible fits (`σ ≤ 0` or `σ > 120°`) are returned as `NaN`.

### Why anchored, not the literal horizon slice
The original `beam_aim.m` reads azimuth off the `el ≈ 0` slice and is checked
call-by-call in a GUI. Run unattended and marker-free, that slice is fragile: when
the mics don't straddle the bat's horizon the interpolant extrapolates at the
sampled-region edge and returns azimuths tens to hundreds of degrees off.
Anchoring to the loudest mic removes that failure mode. Set `method='midline'` to
reproduce the original behaviour, or `method='peak2d'` for an unconstrained
interpolated peak.

### Fallback
Interpolation needs several mics spanning the beam. If a call has fewer than
`min_mics_fit` (default 5) in-view mics, or the fit is unusable, the estimator
returns the **peak-mic** direction and flags it (`method = 'peak'`, driver code
`2`). The peak-mic direction is always saved too, so the two methods can be
compared.

---

## `estimate_beam_direction.m`

```matlab
bd = estimate_beam_direction(mic_xyz, bat_xyz, call_dB, opts)
```

| Input | Shape / units | Meaning |
|---|---|---|
| `mic_xyz` | M×3, metres | candidate mic positions (room/Vicon-global frame) |
| `bat_xyz` | 1×3, metres | bat position at this call (same frame) |
| `call_dB` | M×1, dB | received level at the desired frequency per mic; `NaN`/`Inf` ignored |
| `opts` | struct | see below |

**`opts` fields**

| field | default | meaning |
|---|---|---|
| `method` | `'anchored'` | `'anchored'` \| `'midline'` \| `'peak2d'` |
| `interp_method` | `'rb_rbf'` | `'rb_rbf'` (RBF) \| `'rb_natural'` (natural `griddata`) |
| `min_mics_fit` | `5` | minimum mics to attempt interpolation |
| `anchor_win_deg` | `40` | half-window around the peak mic (deg) |
| `midline_halfwidth_deg` | `1` | half-width of the `el ≈ 0` slice (deg), midline method |
| `grid_step_deg` | `1` | interpolation grid step (deg) |

**Output struct `bd`**

| field | Meaning |
|---|---|
| `az_deg`, `el_deg` | beam-aim azimuth / elevation (deg, room frame) — the head-aim proxy |
| `sigma_deg` | Gaussian beam half-width in azimuth (deg); `NaN` for the peak method or an implausible fit |
| `method` | `'anchored'` \| `'midline'` \| `'peak2d'` \| `'peak'` \| `'none'` |
| `n_mics_used` | number of mics that entered the estimate |
| `peak_az_deg`, `peak_el_deg` | loudest-mic direction (always computed; audit / fallback) |

---

## `run_beamaim_maze.m`

```matlab
out = run_beamaim_maze(cfg)
```

Loops over the calls that have a track (`mic_data.call_idx_w_track`). For each
call it (1) selects the mics with line of sight to the bat (the default; or, in
`'zone'` mode, the static per-zone list), (2) classifies the maze zone from
`proc.bat_loc_at_call` as a trial-level region label (reporting + the stem-zone
fit tweak), (3) reads the dB at `freq_desired` for each selected mic (pairing
each intensity vector with a matching-length frequency axis), then (4) calls
`estimate_beam_direction` and records the result.

**`cfg` fields**

| field | default | meaning |
|---|---|---|
| `bp_proc_file` | — (required) | processed beam file `…_mic_data_bp_proc.mat` |
| `bat_pos_file` | `''` | position-pipeline `bat_pos.mat` (trajectory + embedded `.maze`) for zone classification; if empty, uses a track/maze inside `bp_proc_file` |
| `freq_desired` | `35` | analysis frequency, **kHz** |
| `db_field` | `''` | `''` = auto-pick a compensated dB field, else an explicit `proc` field name |
| `mic_select` | `'lineofsight'` | `'lineofsight'` (default: drop mics whose straight path to the bat crosses a maze wall) or `'zone'` (static per-zone lists) |
| `min_mics_fit_zone2` | `4` | lower `min_mics_fit` for **zone-2 calls only** (the mic-poor stem region), so they can still interpolate |
| `save_back` | `true` | write results back into `bp_proc_file` |
| `est_opts` | anchored preset | options struct forwarded to `estimate_beam_direction` |
| `sync_offset_s` | `0` | **deprecated / unused** — kept only for backward-compatible cfg structs (zone classification now uses `proc.bat_loc_at_call`) |

The default `est_opts` is
`struct('method','anchored','interp_method','rb_rbf','min_mics_fit',5,'anchor_win_deg',40,'grid_step_deg',1)`.

**Fields read from the file:** `proc.<db_field>{calls×mics}` (cell of intensity
vectors), `proc.call_freq_vec{calls×mics}` (per-cell frequency axis, Hz or kHz),
`proc.bat_loc_at_call` (calls×3, m, same frame as `mic_loc`), plus top-level
`mic_loc` (mics×3, m), `mic_names`, `mic_data.fs`, `mic_data.call.call_start_idx`,
`mic_data.call_idx_w_track`, and (optional) `param.RMS_freq_vec`. If `db_field`
is empty the driver auto-picks the first available of:
`call_RMS_dB_comp_re20uPa_withbp`, `call_psd_dB_comp_re20uPa_withbp`,
`call_psd_dB_comp_re20uPa_nobp`, `call_psd_dB_comp_withbp`, `call_rms_dB`.

**Output struct `out`** (and, if `save_back`, written as `proc.*` fields)

| Field | Shape | Meaning |
|---|---|---|
| `beam_aim_az_el_deg` | calls×2 | head-aim proxy azimuth / elevation (deg) |
| `beam_aim_sigma_deg` | calls×1 | azimuth beam half-width σ (deg) |
| `beam_aim_method` | calls×1 | `1` = interpolation-based, `2` = peak-mic fallback, `0` = none |
| `beam_peak_az_el_deg` | calls×2 | loudest-mic direction (audit / continuity) |
| `beam_zone_id` | calls×1 | maze zone 1..5 (`0` = no track / NaN) |
| `beam_sel_mic_num` | calls×1 | loudest selected mic **number** |
| `beam_n_mics_used` | calls×1 | # mics that entered the estimate |

`out` also carries `.zones` (the `build_maze_zones` output); this is **not**
written into `proc`. On save, only the `proc` variable is updated in place
(`save(...,'-append')`) with a short retry loop to ride out transient file locks.

Depends on the stage-2 helpers `build_maze_zones`, `select_mics_by_position`, and
`select_mics_lineofsight`.

---

## `plot_beamaim_qc.m`

```matlab
plot_beamaim_qc(bp_proc_file, out)
plot_beamaim_qc(bp_proc_file, out, arrow_len_m, save_png)
```

Top-view QC in the room frame: numbered mics, the bat position at each call, and a
beam-aim azimuth arrow per call coloured **blue = interpolation + Gaussian fit**
(`method 1`) or **red = peak-mic fallback** (`method 2`). Overlays the full flight
path (solid where Vicon tracked, dashed across gaps, plus the post-TTL landing
tail), the maze walls / start line, and the take-off (gold) and landing (coloured)
perches.

| Input | Default | Meaning |
|---|---|---|
| `bp_proc_file` | — | the `…_bp_proc[_checked].mat` used in `run_beamaim_maze.m` |
| `out` | reads from file | driver output (needs `beam_aim_az_el_deg` + `beam_aim_method`); if omitted, read back from `proc` |
| `arrow_len_m` | `0.3` | arrow length, metres |
| `save_png` | `''` | `''` = auto path in the bat's `plot` folder; `'none'` = don't save; else an explicit file/folder |

If the file carries `takeoff_centered.*`, the plot is drawn in the take-off-centred
frame (`+X` = right arm, `+Y` = deeper) and beam azimuths are rotated by +180° to
match; otherwise it stays in the raw Vicon frame. Saves both a `.png` and a `.fig`.

Run it after `run_beamaim_maze.m` to eyeball whether the proxy head-directions
point sensibly (roughly along the flight / toward where the bat is heading).

*Written by Rie Kaneko on 7/14/2026*
