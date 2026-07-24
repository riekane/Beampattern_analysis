# lib — interpolation & fitting helpers

Small numerical helpers used by `estimate_beam_direction.m` (stage 3), copied in
so the pipeline is self-contained. Added to the path by `setup_paths`.

| File | Role |
|---|---|
| `rbfcreate.m` / `rbfinterp.m` | Radial-basis-function interpolation of the scattered beam samples over the (az, el) sphere. |
| `gaussfit.m` | Least-squares Gaussian fit of the beam's azimuth slice → beam half-width `σ`. |

These are third-party utilities (from the lab toolbox); treat them as black boxes.

---

## `rbfcreate` / `rbfinterp`

```matlab
options = rbfcreate(x, y, 'RBFFunction', kernel, ...)   % build
f       = rbfinterp(xq, options)                        % evaluate
```

- `x` — `dim × n` matrix of node coordinates (here `[az; el]`, radians).
- `y` — `1 × n` values at the nodes (here the per-mic dB).
- `xq` — `dim × nPoints` query coordinates; `f` is the interpolated `1 × nPoints`
  row.
- `kernel` — one of `linear` (default), `cubic`, `multiquadric`, `thinplate`,
  `gaussian`. The interpolant also includes a linear polynomial term.

`estimate_beam_direction` builds the surface with these two functions and then
masks it to the convex hull of the sampled directions, so the beam pattern is
never extrapolated beyond the mics.

> **Note (kernel string):** the estimator requests `'multiquadrics'` (plural),
> which does **not** match the `'multiquadric'` case inside `rbfcreate`; the
> switch therefore falls through to the default **linear** kernel. If a
> multiquadric surface is intended, fix the name to `'multiquadric'`.

## `gaussfit`

```matlab
[sigma, mu] = gaussfit(x, y, sigma0, mu0)
```

Iterative least-squares fit of a Gaussian p.d.f.
`y = 1/(√(2π)·σ)·exp(−(x−μ)²/2σ²)` (max 50 iterations). Returns the standard
deviation `sigma` (used as the beam half-width) and mean `mu`. Optional `sigma0`,
`mu0` seed the iteration if it doesn't converge. The routine auto-normalizes `y`
if it doesn't integrate to ≈1; the estimator discards fits with `σ ≤ 0` or
`σ > 120°` as implausible.

*Written by Rie Kaneko.*
