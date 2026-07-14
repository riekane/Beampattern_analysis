# Third-party notices

This repository bundles code written by others. Their author/copyright headers
are retained in the source files and must stay there when redistributing. This
file summarises each component and its license.

If you make the repository public, please **verify the File Exchange items below**
(their licenses are not stated inside the files) and keep this attribution.

---

## 1. Beampattern processing toolbox — © Wu-Jung Lee, Apache-2.0

Original author: **Wu-Jung Lee** (`leewujung@gmail.com`), 2015, "transplanted
from beampattern_gui_v6.m"; later modifications for the prism project by Shivam.
Licensed under the **Apache License 2.0** (see `LICENSE`).

Bundled verbatim in `1_preprocessing/lib/`:

- `get_call_fcn.m`
- `get_time_series_around_call_fcn.m`
- `compensate_call_dB_fcn.m`
- `find_mic_az_el_to_bat_fcn.m`
- `find_click_range.m`
- `parameters_beam_pattern.mat` (default-parameters data file)

Derived work: `1_preprocessing/bp_proc_vicon.m` reimplements the loading/driver
layer and reuses the functions above; its call-extraction, spectral and
transmission-loss logic follows that toolbox's `bp_proc.m`.

## 2. RBF interpolation — © Alex Chirokov

Author: **Alex Chirokov** (`alex.chirokov@gmail.com`), 16 Feb 2006. Obtained from
the MATLAB Central File Exchange. **License not stated in-file — verify on File
Exchange before redistribution** (File Exchange submissions are commonly BSD).

Files: `3_beam_direction/lib/rbfcreate.m`, `3_beam_direction/lib/rbfinterp.m`

## 3. gaussfit — MATLAB File Exchange

Iterative least-mean-squares Gaussian fit. Obtained from the MATLAB Central File
Exchange. **Author/license not stated in-file — verify on File Exchange before
redistribution.**

File: `3_beam_direction/lib/gaussfit.m`

## 4. air_absorption — © Edward L. Zechmann

Author: **Edward L. Zechmann**, 2006 (rev. 2010). Atmospheric sound absorption
(ISO 9613 / Bass). Obtained from the MATLAB Central File Exchange; the header
grants permission to modify. **Verify File Exchange terms before redistribution.**

File: `1_preprocessing/lib/air_absorption_vec.m`

---

## Everything else

All other source in this repository (the stage drivers, the beam-direction
estimator, the maze mic-selection, the QC plots, `setup_paths.m`) is original
work, © 2026 Rie Kaneko, under the Apache License 2.0 (`LICENSE`).
