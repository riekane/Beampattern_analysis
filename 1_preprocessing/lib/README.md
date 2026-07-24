# lib — preprocessing helpers

Helpers that `bp_proc_vicon.m` (stage 1) depends on, kept here so the pipeline
is self-contained. `bp_proc_vicon` adds this folder to the path automatically.
The DSP helpers are the proven, unmodified lab functions; the two take-off-frame
helpers and the parameter template are project-specific.
Originally from Wu-Jung Lee|leewujung@gmail.com

| File | Role |
|---|---|
| `get_time_series_around_call_fcn.m` | Cut + time-align each on-track call across channels. |
| `get_call_fcn.m` | Per-call spectra (`2·|FFT|²/(N·fs)` PSD) and 1/3-octave RMS levels. |
| `compensate_call_dB_fcn.m` | Transmission-loss + mic-term compensation → source-referenced dB re 20 µPa. |
| `air_absorption_vec.m` | Air absorption `α(f,T,H)` (dB/m) and speed of sound (Bass + ISO 9613). |
| `find_mic_az_el_to_bat_fcn.m` | Mic→bat vectors → azimuth/elevation in the bat head frame (bookkeeping). |
| `find_click_range.m` | Envelope-threshold refinement of call bounds (non-duration path only). |
| `add_takeoff_centered_coords.m` | Add `data.takeoff_centered` (shifted copies for plotting; raw untouched). |
| `shift_to_takeoff_frame.m` | Geometric primitive: map room coords to the take-off-centred maze frame. |
| `parameters_beam_pattern.mat` | Defaults template (`data.param` + `data.track`); trial values overridden by `bp_proc_vicon`. |

The DSP helpers know nothing about the maze, occluder, or head-aim proxy; the
take-off-frame helpers are pure geometry.

---

## DSP chain (called in order by `bp_proc_vicon`)

### `get_time_series_around_call_fcn.m`
```matlab
data = get_time_series_around_call_fcn(data)
```
Extracts a fixed window (`data.param.extract_call_len_pt`) around each call in
`data.mic_data.call_idx_w_track`, from `data.mic_data.sig`. Aligns each channel
to its expected acoustic arrival using `data.time_of_call_at_mic`. Channels with
no mic location become NaN.
**Writes (per call `iC`, shape iC × extract_len_pt × nch):** `proc.call_align`
(distance-aligned), `proc.call_no_align`, `proc.call_align_se_idx`,
`proc.call_no_align_se_idx`, `proc.call_loc_on_track_interp`,
`proc.call_receive_time`.

### `get_call_fcn.m`
```matlab
data = get_call_fcn(data, plot_opt)   % plot_opt = 0 in the pipeline
```
With `data.param.dura_flag = 1`, uses the call_detect start/end marks: builds a
template from the marked channel, cross-correlates it across channels (Hilbert
envelope, tolerance window, first-arrival peak) to carve the call from each mic,
Tukey-tapers, then computes the FFT PSD and a 1/3-octave-band RMS via a
Butterworth filter bank at `data.param.RMS_freq_vec`.
**Reads:** `data.param.{dura_flag,tolerance,tukeywin_proportion,RMS_freq_vec,PSD_type,click_th,click_bpf,call_short_len,call_portion_front}`, `proc.call_align`, `mic_data.{call,fs,num_ch_in_file}`, `mic_loc`.
**Writes (cells, iC × nch):** `call_align_short`, `call_align_short_se_idx`,
`call_fft`, `call_freq_vec`, `call_psd_raw_linear`, `call_psd_raw_dB`,
`call_rms`, `call_rms_dB`, `call_rms_fcenter`.
A bad duration mark prints a diagnostic and fake-fills that call with empty
cells so processing continues.

### `compensate_call_dB_fcn.m`
```matlab
data = compensate_call_dB_fcn(data)
```
Refers each call's PSD to `d0 = 0.1 m` and applies mic terms:
```
TL  = 20·log10(d_m/d0) + α(f,T,H)·(d_m − d0)
comp_withbp    = raw + TL − sens − bp
re20uPa_withbp = comp_withbp + 20·log10(1/20e-6) − gain
```
`α` = Bass absorption from `air_absorption_vec`; `sens`/`bp` interpolated from
`data.mic_sens` / `data.mic_bp`.
**Writes:** `proc.call_psd_dB_comp_{nobp,withbp}`,
`proc.call_psd_dB_comp_re20uPa_{nobp,withbp}` (downstream input),
`proc.call_p2p_SPL_comp_re20uPa`, `proc.call_RMS_SPL_comp_re20uPa`, plus the
component terms `TL_dB`, `air_attn_dB`, `spreading_loss_dB`, `mic_sens_dB`,
`mic_bp_compensation_dB`, and `param.{d0,alpha,alpha_iso}`.

---

## Physics / geometry helpers

### `air_absorption_vec.m`
```matlab
[alpha, alpha_iso, c, c_iso] = air_absorption_vec(f, T, hr, ps)
```
`f` in Hz (vector ok), `T` in °C, `hr` in %RH, `ps` pressure ratio (default 1).
Returns absorption `alpha` (Bass) and `alpha_iso` (ISO 9613) in dB/m, and speed
of sound `c` (Bass) and `c_iso` (ISO) in m/s. The pipeline uses `alpha` for
transmission loss and `c` for time-of-flight.

### `find_mic_az_el_to_bat_fcn.m`
```matlab
[mic2bat_2d, mic2bat_x] = find_mic_az_el_to_bat_fcn(mic_to_bat_vec, aim_v, norm_v)
```
Rotates mic→bat unit vectors into the bat head frame (head aim `aim_v`, head
normal `norm_v`) and returns spherical `[azimuth, elevation, radius]` in radians
(N×3). `mic2bat_x` is the back-hemisphere-corrected variant for cross plots.
Internal bookkeeping only.

### `find_click_range.m`
```matlab
click_idx = find_click_range(sig, sig_max, sig_max_loc, th, numfilt)
```
Filters `sig`, takes the smoothed Hilbert envelope, and returns the `[start end]`
sample indices where the envelope crosses `sig_max·th` around `sig_max_loc`
(`NaN` if none). Only used on the non-duration (`dura_flag = 0`) path, so it is
not exercised by this pipeline's default settings.

---

## Take-off-centred coordinate
*Written by Rie Kaneko*

### `add_takeoff_centered_coords.m`
```matlab
data = add_takeoff_centered_coords(data)
```
Adds a single field `data.takeoff_centered` holding shifted copies of every
plotted location/vector, leaving all raw fields untouched (so existing analysis
is unaffected; the copies are purely for intuitive plotting).
**Fields added:** `pivot_mm`, `pivot_m`, `info`, `mic_loc`, `mic_vec`,
`bat_loc_at_call`, `mic_to_bat_vec`,
`track.{marked_pos,track_raw,track_smooth,track_interp,track_tail}`,
`head_aim_int`, `head_normal_int`,
`maze.{left_wall,right_wall,start_line,takeoff_perch,landing_perch}`,
`tp_position`, `lp_position`, `perch_pos`.
Metre-unit fields are shifted with the pivot in metres; maze/perch fields (mm)
with the pivot in mm. The pivot (take-off perch, marker 1) is taken from
`perch_pos.takeoff.marker1`, else `tp_position`, else `maze.takeoff_perch`; if
none is found it warns and adds nothing.

### `shift_to_takeoff_frame.m`
```matlab
tc = shift_to_takeoff_frame(P, tp_xy, 'loc')   % positions (default)
tc = shift_to_takeoff_frame(P, [],    'vec')   % direction vectors
```
The geometric primitive: a 180° rotation about the vertical axis through the
take-off perch.
```
locations (kind='loc'):  x' = tpx − x ;  y' = tpy − y ;  z' = z
vectors   (kind='vec'):  x' = −x       ;  y' = −y       ;  z' = z
```
`P` may be N×3, a single `[x y z]` (1×3 or 3×1), or an M×N×3 stack whose last
dim is `[x y z]`; column 3 and any further columns pass through unchanged and
NaNs are preserved. `tp_xy = [tpx tpy]` must be in the same units as `P`
(ignored for `'vec'`).

**Frame conventions.** Take-off becomes the XY origin; the maze extends toward
+Y as the bat flies deeper; Z is unchanged. Because X is negated, in this frame
**+X reads as the RIGHT arm** (raw Vicon had +X = LEFT). It is a proper
rotation, so physical left/right is preserved — only the sign label flips. Judge
left/right from these coordinates, not the old "+X = left" rule.

*Updated by Rie Kaneko on 7/22/2026*
*README Written by Rie Kaneko on 7/24/2026*
