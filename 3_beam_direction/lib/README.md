# lib — interpolation & fitting helpers

Small numerical helpers used by `estimate_beam_direction.m` (stage 3), copied in
so the pipeline is self-contained. Added to the path by `setup_paths`.

| File | Role |
|---|---|
| `rbfcreate.m` / `rbfinterp.m` | Radial-basis-function interpolation (multiquadric) of the scattered beam samples over the (az, el) sphere. |
| `gaussfit.m` | Least-squares Gaussian fit of the beam's azimuth slice → beam half-width `σ`. |

Third-party utilities (from the lab toolbox); treat as black boxes.
