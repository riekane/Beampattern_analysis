# lib — preprocessing signal-processing helpers

Reused, unmodified helpers that `bp_proc_vicon.m` (stage 1) depends on, copied in
so the pipeline is self-contained. `bp_proc_vicon` adds this folder to the path
automatically.

| File | Role |
|---|---|
| `get_time_series_around_call_fcn.m` | Cut + time-align each call across channels. |
| `get_call_fcn.m` | Spectra: `|FFT|²` PSD and 1/3-octave RMS levels per call. |
| `compensate_call_dB_fcn.m` | Transmission-loss + mic-term compensation → source-referenced dB. |
| `air_absorption_vec.m` | Air absorption `α(f,T,H)` (dB/m) and speed of sound (ISO 9613 / Bass). |
| `find_mic_az_el_to_bat_fcn.m` | Mic→bat vectors → azimuth/elevation (internal bookkeeping). |
| `find_click_range.m` | Envelope-threshold refinement of call bounds (used on the non-duration path). |
| `parameters_beam_pattern.mat` | Defaults template (`data.param` + `data.track`); trial-specific values are overridden by `bp_proc_vicon`. |

These are pure signal processing — they know nothing about the occluder or the
head-aim proxy.
