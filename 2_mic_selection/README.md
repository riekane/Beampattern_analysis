# Stage 2 — Microphone selection (occluder-aware)

**Input:** the bat position for a call.
**Output:** the set of microphone **numbers** whose line of sight to the bat is
not blocked by the occluder at that position.

**Purpose** Stage 3 finds the beam direction by looking for the loudest
direction. A microphone the occluder blocks records a weak, misleading level; if
left in, it drags the interpolated peak toward a wall. So before estimating
direction, restrict the candidates to the mics that can actually see the bat.

---

## Files

| File | Role |
|---|---|
| `build_maze_zones.m` | Turns the occluder landmark coordinates into a compact "zones" model (boundary lines + a microphone set per region). Build once per session. |
| `select_mics_by_position.m` | The core map: bat `(x,y)` → region id → allowed microphone numbers. |
| `plot_mic_selection_qc.m` | QC figure: regions, boundaries, trajectory and mics — run first to check the geometry. |

---

## The logic / math

**Regions as an exhaustive partition.** The flight area is split into a small set
of mutually exclusive regions. Every bat position falls in exactly one — there is
no "unclassified" fallback.

**Classification = point vs. boundary lines.** Each boundary is a straight
segment between two landmark points. Classifying a position reduces to cheap
sign/interval tests: evaluate the relevant boundary line at the bat's coordinate
and check which side the bat is on. Concretely, a boundary line through points
`p1,p2` is evaluated at the bat's `x` (or `y`):

```
y_boundary(x) = p1_y + (p2_y − p1_y) · (x − p1_x)/(p2_x − p1_x)
bat is "above"  ⇔  bat_y > y_boundary(bat_x)
```

A short decision tree of such tests (is the bat before the occluder? outside a
side wall? past the junction?) assigns the region id. `build_maze_zones` stores
the boundary points; `select_mics_by_position` runs the tests.

**Region → microphone set.** Each region carries a list of microphone numbers and
a mode:
- `INCLUDE` — use only these mics.
- `EXCLUDE` — use all present mics except these (the ones the occluder blocks
  for that region).

The list is intersected with the mics actually available this session, so
missing/aimed-away mics drop out automatically. Sets and modes are overridable
via `opts` to `build_maze_zones` — no need to edit code to retune them.

> Geometry specifics (which landmark defines which boundary, the exact per-region
> mic lists) are documented in the function headers, where they belong, and are
> easy to adjust there. This README is about the *method*, not the particular
> occluder layout.
