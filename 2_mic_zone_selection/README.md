# Stage 2 — Microphone selection (occluder-aware)

**Input (per call):** the bat position `(x, y)` in the Vicon global frame (mm).
**Output:** the set of microphone **numbers** to keep for that call — the mics
with a clear line of sight to the bat, not the ones a maze wall blocks.

**Why.** Stage 3 estimates the beam direction by finding the loudest direction
(interpolation + Gaussian fit). A microphone blocked by a maze wall records a
weak, misleading level; left in, it drags the interpolated peak toward a wall.
So before estimating direction we restrict the candidate mics to those that can
actually see the bat.

---

## Two separate roles — don't conflate them

This stage does two independent things with the bat's position:

1. **Per-call microphone selection — line-of-sight (the default).** For each
   call, keep a mic only if the straight XY line from the bat to that mic does
   **not** cross a maze wall. This is the filter that decides which mics feed the
   beam estimate. `run_beamaim_maze` uses it by default
   (`cfg.mic_select = 'lineofsight'`).

2. **Trial-level zone categorization.** Separately, the bat's position is
   classified into one of five maze **zones** (approach / stem / junction / left
   arm / right arm). The zone is a coarse **region label**, *not* the per-call
   mic filter — it is used to group and report calls by where in the maze they
   were emitted, and to give the mic-poor stem zone a lower interpolation
   threshold in stage 3. Every call still gets a `zone_id` even under
   line-of-sight selection.

A  **`'zone'` selection mode** also exists, in which the per-call mic set
comes from static per-zone INCLUDE/EXCLUDE lists instead of geometry. It is still
available via `cfg.mic_select = 'zone'`: the
static lists can exclude mics that in fact see the forward beam (e.g. when the
bat is below the exits), which is exactly what line-of-sight fixes.

Both roles are built on the same `zones` model produced once per session by
`build_maze_zones.m`.

---

## Files

| File | Role |
|---|---|
| `select_mics_lineofsight.m` | **Default per-call selector.** Keeps mics with an unobstructed XY line of sight to the bat. |
| `build_maze_zones.m` | Turns raw Y-maze landmark coordinates into a compact `zones` struct (boundary lines + a mic set/mode per zone). Build once per session. |
| `select_mics_by_position.m` | Classifies a bat `(x,y)` into one of 5 zones. Provides the trial-level zone label (reporting + the stem-zone fit tweak), and the mic set for the legacy `'zone'` selection mode. |
| `plot_mic_zone_selection_qc.m` | QC figure: filled zones, boundaries, walls, trajectory, perches and mics. Run first to check the geometry. |

---

## Line-of-sight selection (default)

```matlab
[mic_nums, vis, qc] = ...
        select_mics_lineofsight(bat_xy, mics_xy, all_mic_nums, walls)
```

Keeps a mic only if the straight XY segment bat → mic does **not** cross any maze
wall segment (strict segment-intersection test; collinear/endpoint touches
ignored). Handles every bat position uniformly — inside the maze the walls
occlude the far side; below the exits the space is open and most mics pass.

| arg | type | meaning |
|---|---|---|
| `bat_xy` | `[x y]` | bat position, mm |
| `mics_xy` | `N×2` | mic positions (mm), **same order as `all_mic_nums`** |
| `all_mic_nums` | `1×N` | mic numbers present/usable this session |
| `walls` | cell of `K×2` | wall polylines, e.g. `{zones.wallR, zones.wallL}`; consecutive rows = segments |
| **returns** | | |
| `mic_nums` | vector | visible mic numbers |
| `vis` | `N×1` logical | per-mic visibility mask |
| `qc` | struct | `n_visible`, `n_total` |

`run_beamaim_maze` calls it with `mics_xy = mic_loc(:,1:2)*1000` (mm) and
`walls = {zones.wallR, zones.wallL}`.

> Line-of-sight is **XY-only**: wall heights are not in the layout, so walls
> block regardless of height. This is reasonable for a bat flying between the
> walls; revisit if mics are mounted high enough to see over a wall. The function
> does not return a zone id — the zone label is computed separately (below).

---

## The five zones (trial-level region categorization)

The flight area is an **exhaustive, mutually-exclusive** partition — every bat
position falls in exactly one zone (there is no "unclassified" fallback). The
bat flies from the take-off perch (Y ≈ +1560) toward the exits (Y ≈ −3220), so
**Y decreases along the flight.** The zone is a region label; it does not, by
itself, choose the mics under the default line-of-sight selection.

| id | key | display name | where |
|---|---|---|---|
| 1 | `approach` | pre-maze entrance | above the start line |
| 2 | `inside_y` | maze pre-junction | between the walls, above the tips of the Y (the stem) |
| 3 | `past_y` | maze past-junction | between the walls, below the tips of the Y (the wedge past the junction) |
| 4 | `arm_purple` | **left arm** (**+X** side, toward `maze_exit_left`) | outside the +X wall |
| 5 | `arm_pink` | **right arm** (**−X** side, toward `maze_exit_right`) | outside the −X wall |

> **Label note.** In the raw JSON the object called "left wall" holds the
> `*_right` points and sits on the **−X** side; "right wall" holds the `*_left`
> points on **+X**. Everything downstream is keyed off point *coordinates*, so
> the swapped names never affect the result. Internally
> `zones.wallR = maze.left_wall` (−X, pink) and `zones.wallL = maze.right_wall`
> (+X, purple).

> **Stem-zone fit tweak.** Zone 2 (`inside_y`) is mic-poor. Regardless of the
> selection mode, stage 3 lowers its `min_mics_fit` for zone-2 calls only
> (`cfg.min_mics_fit_zone2`, default 4) so those calls can still attempt
> interpolation instead of falling back to the loudest single mic.

> **Frame — the ±X signs above are RAW Vicon.** Zone classification runs in the
> raw Vicon frame (on `proc.bat_loc_at_call`), so `+X` = left arm (`arm_purple`)
> and `−X` = right arm (`arm_pink`) exactly as listed. The take-off-centred
> display frame is a 180° rotation about the perch (`x' = tp_x − x`) that
> **flips the X sign**, so in *that* frame `+X` is the RIGHT arm. The two frames
> disagree by design: zones are assigned in the raw frame, and the ±X labels
> only invert once you have applied the take-off shift (e.g. when plotting in the
> take-off-centred view).

### Boundaries and classification math

Each boundary is a straight segment between two named landmark points.
Classifying a position reduces to cheap sign/interval tests.

**Slanted lines evaluated at the bat's X** (start line, tips-of-Y line):

```
y_boundary(x) = p1_y + (p2_y − p1_y) · (x − p1_x)/(p2_x − p1_x)
bat is "above"  ⇔  bat_y > y_boundary(bat_x)
```

**Walls evaluated at the bat's Y.** Each wall is the 3-point polyline
`enter → y-join → exit`. Its X at a given height splits into three pieces
(`wall_x_at_y`):

| height range | segment used |
|---|---|
| `y ≥ y-join Y` | stem `maze_enter → maze_y-join` |
| `exit Y ≤ y < y-join Y` | diagonal `maze_y-join → maze_exit` |
| `y < exit Y` | **vertical** at `maze_exit` X (boundary drops straight down) |

**Decision order** (`select_mics_by_position`):

```matlab
if y > y_start                 % zone 1 approach
elseif x < x_wallR             % zone 5 arm_pink  (−X)
elseif x > x_wallL             % zone 4 arm_purple(+X)
elseif y > y_tips              % zone 2 inside_y  (stem)
else                           % zone 3 past_y    (wedge)
end
```

Boundary-defining points:

| boundary | points | evaluated at |
|---|---|---|
| start line | `maze_enter_far-right — maze_enter_far-left` | bat X |
| tips of Y | `maze_y-join_right — maze_y-join_left` | bat X |
| −X wall | `maze_enter_right — maze_y-join_right — maze_exit_right` | bat Y |
| +X wall | `maze_enter_left — maze_y-join_left — maze_exit_left` | bat Y |

---

## Zone → microphone set (zone selection mode)

Used only when `cfg.mic_select = 'zone'`. Each zone carries a list of microphone
**numbers** and a **mode**:

- `INCLUDE` — use only these mics (`intersect` with the session mics).
- `EXCLUDE` — use all session mics *except* these (`setdiff`), i.e. the ones the
  occluder blocks for that zone.

The list is always intersected/differenced against the mics actually available
this session, so missing, NaN (e.g. channels 22/23/24) or aimed-away mics drop
out automatically.

Defaults (overridable — see below):

| zone | mode | mic numbers |
|---|---|---|
| `approach` | EXCLUDE | `1 17 4 20 32` |
| `inside_y` | INCLUDE | `2 3 18 19` |
| `past_y` | INCLUDE | `1 2 3 4 5 6 15 16 17 18 19 20 21 31 32` |
| `arm_purple` (+X / left) | EXCLUDE | `6 21 7 5 10 24 8 2 26` |
| `arm_pink` (−X / right) | EXCLUDE | `31 16 11 29 13 28 27` |

Sets and modes can be retuned without editing code, via `opts` to
`build_maze_zones` (`opts.mic_sets`, `opts.mic_modes`; any subset of the five
zone fields).

---

## Functions

### `build_maze_zones`

```matlab
zones = build_maze_zones(maze)        % defaults
zones = build_maze_zones(maze, opts)  % override mic sets / modes
```

**Input** — `maze`: struct in the Vicon global frame (mm), exactly the one saved
inside every `bat_pos.mat` (`bat_pos.maze`; also from `extract_maze_structure`).
Rows are points in JSON order:

| field | shape | contents |
|---|---|---|
| `left_wall` | `3×3` | `maze_enter_right; maze_y-join_right; maze_exit_right` (−X side) |
| `right_wall` | `3×3` | `maze_enter_left; maze_y-join_left; maze_exit_left` (+X side) |
| `start_line` | `2×3` | `maze_enter_far-right; maze_enter_far-left` |
| `takeoff_perch` | `1×3` | optional, plotting only |

**Output** — `zones` struct:

| field | shape | meaning |
|---|---|---|
| `start_p1`, `start_p2` | `1×2` | start-line endpoints `[x y]` |
| `tips_p1`, `tips_p2` | `1×2` | the two `maze_y-join` points `[x y]` |
| `wallR` | `3×2` | −X wall polyline `enter; y-join; exit` (passed to line-of-sight) |
| `wallL` | `3×2` | +X wall polyline (passed to line-of-sight) |
| `exit_p1`, `exit_p2` | `1×2` | exit points (plotting) |
| `mic_sets` | struct | per-zone mic numbers + `*_mode` (legacy `'zone'` mode) |
| `zone_names` | `1×5` cell | display names |
| `zone_keys` | `1×5` cell | internal keys |
| `maze` | struct | the original `maze`, passed through |

### `select_mics_lineofsight`  (default per-call selector)

See *Line-of-sight selection* above.

### `select_mics_by_position`  (zone label + legacy `'zone'` mode)

```matlab
[mic_nums, zone_id, zone_name, qc] = ...
        select_mics_by_position(bat_xy, zones, all_mic_nums)
```

Returns both the trial-level **zone label** (used for reporting and the stem-zone
fit tweak under any selection mode) and the per-zone **mic set** (used only when
`cfg.mic_select = 'zone'`).

| arg | type | meaning |
|---|---|---|
| `bat_xy` | `[x y]` or `[x y z]` | bat position, mm, Vicon global |
| `zones` | struct | from `build_maze_zones` |
| `all_mic_nums` | vector | mic numbers present/usable this session |
| **returns** | | |
| `mic_nums` | row vector | per-zone mic numbers (legacy mode) |
| `zone_id` | `1..5` | region label; `0` if `bat_xy` is NaN |
| `zone_name` | char | display name, or `'nan'` |
| `qc` | struct | boundary values used: `y_start`, `y_tips`, `x_wallR`, `x_wallL` |

### `plot_mic_zone_selection_qc`

```matlab
plot_mic_zone_selection_qc(bat_pos_file)
plot_mic_zone_selection_qc(bat_pos_file, mic_pos_file)
plot_mic_zone_selection_qc(bat_pos_file, mic_pos_file, save_png)
```

Draws the XY (top) view: the five zones as filled regions (from classifying a
dense grid), the maze walls, start line, tips-of-Y line, the two below-exit
vertical boundaries, the bat trajectory, the take-off perch (gold star) and
landing perch (cyan diamond), and labelled mic squares. Classification is done
in the raw frame; only the display is rotated 180° about the take-off perch so
take-off → `(0,0)` and deeper-in-maze → `+Y`.

| arg | meaning |
|---|---|
| `bat_pos_file` | a `bat_pos.mat` (embeds the `.maze` and the trajectory) |
| `mic_pos_file` | optional `mic_pos_<date>.mat` or `.csv` to plot mics (CSV cols `pos_X_mm, pos_Y_mm, mic_name`; MAT vars `mic_pos, mic_names`) |
| `save_png` | `''` = auto-save into the bat's `plot/` folder under the processed-data output root; `'none'` = don't save; a folder/path = save there |

The QC figure is written as both a `.png` and a matching `.fig`, and the
per-zone frame counts are printed to the console.

---

*Written by Rie Kaneko on 7/14/2026*
*Updated by Rie Kaneko on 7/23/2026*

