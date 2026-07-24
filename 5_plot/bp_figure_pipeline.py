#!/usr/bin/env python3
r"""
BEAMPATTERN FIGURE PIPELINE  (batch-friendly, one place to edit)
================================================================
Edit the CONFIG block and run:  python bp_figure_pipeline.py

  SUBJECT         one bat, e.g. 'batA125'
  SESSIONS        list of one or more 'YYYYMMDD' sessions
  ACROSS_SESSION  True  -> pool ALL listed sessions' trials into ONE figure
                  False -> make one figure per session

Auto-locates ...\Beampattern_proc\<SUBJECT>\beampattern_output\ (no paths to edit).
Saves PNGs into this folder (5_plot) as <SUBJECT>_<sessiontag>_<figname>.png .
Also writes every trial + every call to ONE SQLite database (beampattern.db) and
a Parquet/CSV mirror next to it (see bp_db.py). Add a figure: write fig_*(D, meta)
and append it to FIGURES. Needs numpy + matplotlib + h5read.py + beamlib.py +
bp_db.py (already here). No MATLAB.

FIGURE POLICY (conference figures):
  * invisible-from-perch blocked trials are DROPPED from every junction figure
    (they can bias the choice at the junction, so they don't belong on the
    "natural behaviour" plots). They are still stored in the database.
  * visible-from-perch blocked trials STAY and are drawn exactly like normal
    controls (no hatch / no separate colour) -- the manipulation only affects
    the pre-flight call, not the junction. Their 'visible' label lives in the DB.
"""
import os, sys, glob, re
import numpy as np
import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt

# ======================= CONFIG - EDIT THESE =======================
SUBJECT        = 'batA125'
SESSIONS       = ['20260710', '20260714']   # one or many
ACROSS_SESSION = True     # True = combine sessions into one figure; False = one per session
# --- overlay MULTIPLE bats in the two beam-direction figures (each bat drawn separately) ---
SUBJECTS       = None      # e.g. ['batA125', 'batFB80']; leave None for single-subject (uses SUBJECT)
ACROSS_SUBJECT = False     # True + SUBJECTS -> ONE beam-direction figure with each bat overlaid (marker per bat)
# --- restrict / annotate the two beam-direction figures (LR_split + angle) ---
BEAM_SIDES     = None       # None = both choice sides; ['RIGHT'] or ['LEFT'] = show ONLY that side
FIG_NOTE       = ''         # optional italic caption drawn under the beam-direction figures (e.g. a behavioural note)
# ===================================================================

# ---- trial condition labels ----------------------------------------
# Filled interactively by the "label_trials()" form cell below. Labels are now
# PERSISTED in the SQLite database, so once you have tagged a trial the form
# pre-fills it and you never have to type it again -- only brand-new / untagged
# trials come up blank. You can also hardcode labels here instead:
#   TRIAL_LABELS[session][trial] = {'blocked':True,'side':'LEFT','vis':'invisible'}
#   side = which side the block is on ('LEFT' / 'RIGHT')
#   vis  = target as seen from the perch: 'visible' or 'invisible'
#          visible   -> can affect the PRE-FLIGHT call, NOT the choice
#          invisible -> can affect the CHOICE at the junction, NOT the pre-flight call
# Trials not listed are treated as 'normal' (unblocked control).
TRIAL_LABELS = {}

# Optional EXTRA restriction on which visibility groups feed the junction figures.
# (Invisible trials are ALWAYS dropped from figures regardless of this -- see policy
# above. This knob just lets you restrict further, e.g. to only 'visible'.)
#   None -> default (all trials except invisible)
JUNCTION_VIS = None

# zone numbering (beamlib ZONE_KEYS): 1=approach  2=inside_y  3=past_y(junction)
#   4=arm_purple(LEFT)  5=arm_pink(RIGHT)
JUNCTION_ZONE = 3
# 'PRE-FLIGHT' and 'ZONE 1' are DIFFERENT and are reported as separate columns:
#   pre-flight = calls emitted BEFORE take-off (bat still on the perch), found from
#                each trial's take-off frame (call idx <= takeoff) -- NOT a spatial zone
#   zone 1     = 'approach', the in-flight segment near the perch (spatial zone id 1)
# ===================================================================

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import beamlib as B
import bp_db

def _pick(cands):
    for c in cands:
        if c and os.path.isdir(c): return c
    return cands[0]
BP_ROOT = _pick([r'Z:\Rie\Data\Beampattern_proc'] + sorted(glob.glob('/sessions/*/mnt/Beampattern_proc')))
OUT_DIR = _pick([r'Z:\Rie\Analysis\Beampattern_analysis\5_plot'] + sorted(glob.glob('/sessions/*/mnt/5_plot')) + [os.path.dirname(os.path.abspath(__file__))])

# one database + flat mirror for ALL subjects (queryable from Python and MATLAB)
DB_PATH  = os.path.join(OUT_DIR, 'beampattern.db')
FLAT_DIR = OUT_DIR

def wrap(d): return (d + 180) % 360 - 180
def _f(x):   return None if (x is None or not np.isfinite(x)) else float(x)
def _rd(h, p):
    try:
        a = h.read(p); return None if a is None else np.asarray(a)
    except Exception:
        return None
def winvel(x3, dt, Wf, comp=None):
    F = x3.shape[1]; v = np.full(F, np.nan)
    for i in range(Wf, F - Wf):
        d = x3[:, i + Wf] - x3[:, i - Wf]
        v[i] = (d[comp] / (2 * Wf * dt)) if comp is not None else np.sqrt(np.sum(d ** 2)) / (2 * Wf * dt)
    return v
def takeoff_frame(ti, tt, tp):
    F = ti.shape[1]; dt = np.median(np.diff(tt)); rate = 1 / dt; Wf = max(1, int(round(0.020 * rate)))
    sp = winvel(ti, dt, Wf); vz = winvel(ti, dt, Wf, 2); dxy = np.hypot(ti[0] - tp[0], ti[1] - tp[1])
    valid = np.all(np.isfinite(ti), axis=0); fv = int(np.argmax(valid)); lv = F - 1 - int(np.argmax(valid[::-1]))
    hold = max(1, int(round(0.10 * rate))); look = max(1, int(round(0.20 * rate)))
    for f in range(fv, lv - hold + 1):
        if not valid[f] or not (np.isfinite(sp[f]) and sp[f] >= 0.5): continue
        if not (np.isfinite(vz[f]) and vz[f] <= -0.25): continue
        w = dxy[f:min(lv + 1, f + look)]
        if np.nanmax(w) > 0.30:
            g = f + int(np.nanargmax(w > 0.30))
            if np.nanmean(dxy[g:g + hold] > 0.30) >= 0.9: return f
    onp = valid & (dxy <= 0.30)
    return (min(np.where(onp)[0][-1] + 1, lv) if onp.any() else fv)

def list_trials(subject, session):
    """Trial numbers available for a session (scanned from bp_proc filenames)."""
    bp_dir = os.path.join(BP_ROOT, subject, 'beampattern_output')
    ts = []
    for f in sorted(glob.glob(os.path.join(bp_dir, f'{session}_T*_*bp_proc.mat'))):
        mo = re.search(r'_T0*([0-9]+)_', os.path.basename(f))
        if mo: ts.append(int(mo.group(1)))
    return sorted(set(ts))

def _label(session, trial):
    return TRIAL_LABELS.get(session, {}).get(trial, {'blocked': False, 'side': None, 'vis': 'normal'})

def _merge_db_labels(subject, sessions):
    """Pull saved labels out of the database into TRIAL_LABELS so BOTH the batch
    script and the notebook tag trials without re-typing. In-memory / form values
    win over the DB if both exist."""
    try:
        saved = bp_db.read_labels(DB_PATH, subject, sessions)
    except Exception as e:
        print('  [db] could not read saved labels (%s) -- treating all as normal' % type(e).__name__); return
    for s, trials in saved.items():
        TRIAL_LABELS.setdefault(s, {})
        for t, info in trials.items():
            TRIAL_LABELS[s].setdefault(int(t), info)

def label_trials(subject=None, sessions=None):
    """Popup form: for each trial pick the BLOCK SIDE (LEFT/RIGHT) and the perch
    view (visible/invisible). Trials you have ALREADY tagged (saved in the
    database) come up PRE-FILLED -- you only need to fill brand-new blank ones.
    Click 'Save labels' (writes to the database), then run the pipeline cell.
    If ipywidgets is missing it prints a TRIAL_LABELS template (pre-filled from
    the database) you can paste into the CONFIG cell instead."""
    subject  = subject  or SUBJECT
    sessions = sessions if sessions is not None else ([SESSIONS] if isinstance(SESSIONS, str) else SESSIONS)
    detected = {s: list_trials(subject, s) for s in sessions}
    saved = bp_db.read_labels(DB_PATH, subject, sessions)          # {s:{t:{blocked,side,vis}}}
    def cur(s, t):
        return (TRIAL_LABELS.get(s, {}).get(t) or saved.get(s, {}).get(t)
                or {'blocked': False, 'side': None, 'vis': 'normal'})
    try:
        import ipywidgets as W
        from IPython.display import display
    except Exception:
        print("ipywidgets not installed -> paste/fill TRIAL_LABELS in the CONFIG cell.")
        print("(pre-filled below from anything already saved in the database)\n")
        print("TRIAL_LABELS = {")
        for s in sessions:
            saved_s = {t: cur(s, t) for t in detected[s] if (cur(s, t)['blocked'] or cur(s, t)['vis'] != 'normal')}
            if saved_s:
                items = ", ".join("%d: {'blocked':%r,'side':%r,'vis':%r}" %
                                  (t, v['blocked'], v['side'], v['vis']) for t, v in saved_s.items())
                print("    '%s': {%s}," % (s, items))
            else:
                ex = detected[s]
                print("    '%s': {%s: {'blocked':True,'side':'LEFT','vis':'invisible'}}," % (s, ex[0] if ex else 0))
        print("}")
        print("\ndetected trials:", detected); return
    SIDE = ['—', 'LEFT', 'RIGHT']; VIS = ['—', 'visible', 'invisible']
    refs = {}; boxes = []
    for s in sessions:
        refs[s] = {}
        rows = [W.HTML('<b>Session %s</b> &nbsp; (%d trials) &nbsp; '
                       '<span style="color:#888">pre-filled trials are already saved — just fill the blanks</span>'
                       % (s, len(detected[s])))]
        for t in detected[s]:
            c = cur(s, t)
            side_v = c['side'] if c['side'] in SIDE else '—'
            vis_v  = c['vis']  if c['vis']  in VIS  else '—'
            is_saved = (c['blocked'] or c['vis'] != 'normal')
            side = W.Dropdown(options=SIDE, value=side_v, layout=W.Layout(width='100px'))
            vis  = W.Dropdown(options=VIS,  value=vis_v,  layout=W.Layout(width='120px'))
            refs[s][t] = (side, vis)
            tag = W.HTML('<span style="color:#2E86C1">✓ saved</span>' if is_saved else '')
            rows.append(W.HBox([W.Label('T%d' % t, layout=W.Layout(width='55px')),
                                W.Label('block side:'), side, W.Label('perch view:'), vis, tag]))
        boxes.append(W.VBox(rows))
    btn = W.Button(description='Save labels', button_style='success'); status = W.Output()
    def _save(_):
        TRIAL_LABELS.clear(); n = 0
        for s in sessions:
            TRIAL_LABELS[s] = {}
            for t, (side, vis) in refs[s].items():
                sd = None if side.value == '—' else side.value
                vv = 'normal' if vis.value == '—' else vis.value
                if (sd is not None) or (vv != 'normal'):
                    TRIAL_LABELS[s][t] = {'blocked': True, 'side': sd, 'vis': vv}; n += 1
        try:
            bp_db.write_labels(DB_PATH, subject, TRIAL_LABELS)
            db_note = ' (saved to database: %s)' % DB_PATH
        except Exception as e:
            db_note = ' [WARNING: could not write to database: %s]' % e
        with status:
            status.clear_output()
            print('saved %d blocked trial(s)%s:' % (n, db_note), {s: v for s, v in TRIAL_LABELS.items() if v})
            print('now run the pipeline cell below.')
    btn.on_click(_save)
    display(W.VBox(boxes + [btn, status]))

# LEFT arm = arm_purple = zone4 = room +X = maze right_wall exit ; RIGHT arm = arm_pink = zone5 = room -X = left_wall exit
def load_session(subject, session):
    bp_dir = os.path.join(BP_ROOT, subject, 'beampattern_output')
    files = sorted(glob.glob(os.path.join(bp_dir, f'{session}_T*_*bp_proc.mat')))
    if not files: raise FileNotFoundError(f'No bp_proc files in {bp_dir} for {session}')
    trials = []
    for f in files:
        tn = int(re.search(r'_T0*([0-9]+)_', os.path.basename(f)).group(1))
        h = B.open_trial(f); az2 = _rd(h, 'proc/beam_aim_az_el_deg')
        if az2 is None: continue
        az, el = az2[0], az2[1]
        z = _rd(h, 'proc/beam_zone_id').ravel(); ct = _rd(h, 'proc/call_receive_time').ravel()
        bl = _rd(h, 'proc/bat_loc_at_call'); idx = _rd(h, 'track/call_loc_idx_on_track_interp').ravel().astype(int)
        ti = _rd(h, 'track/track_interp'); ti = ti if ti.shape[0] == 3 else ti.T
        tt = _rd(h, 'track/track_interp_time').ravel()
        tp = _rd(h, 'tp_position').ravel() / 1000.0; lp = _rd(h, 'lp_position').ravel() / 1000.0
        LEFT_exit = _rd(h, 'maze/right_wall')[:2, 2] / 1000.0; RIGHT_exit = _rd(h, 'maze/left_wall')[:2, 2] / 1000.0
        n = min(len(az), len(z), len(ct), bl.shape[1], len(idx))
        az, el, z, ct, bl, idx = az[:n], el[:n], z[:n], ct[:n], bl[:, :n], idx[:n]
        arm = np.isin(z, [4, 5]) & np.isfinite(ct)
        if not arm.any(): continue
        ka = np.where(arm)[0]; first = int(z[ka[np.argmin(ct[ka])]]); side = 'LEFT' if first == 4 else 'RIGHT'
        lab = _label(session, tn)
        trials.append(dict(trial=tn, session=session, subject=subject, az=az, el=el, zone=z, ct=ct, bat=bl, idx=idx,
                           ti=ti, tt=tt, tp=tp, lp=lp, LEFT_exit=LEFT_exit, RIGHT_exit=RIGHT_exit,
                           takeoff=takeoff_frame(ti, tt, tp), side=side,
                           vis=lab['vis'], blocked=lab['blocked'], block_side=lab['side']))
    return trials

def _lat(az_deg, bx, by, left_exit, right_exit):
    """+1 = beam/heading fully toward LEFT arm, -1 = fully toward RIGHT arm (uses that trial's own arm geometry)."""
    bl = np.degrees(np.arctan2(left_exit[1] - by, left_exit[0] - bx))
    br = np.degrees(np.arctan2(right_exit[1] - by, right_exit[0] - bx))
    return np.cos(np.radians(wrap(az_deg - bl))) - np.cos(np.radians(wrap(az_deg - br)))

def _ang(az_deg, bx, by, left_exit, right_exit):
    """Signed angle (deg) of a direction relative to the maze MIDLINE (the straight-ahead
    axis that bisects the two arms): 0 = straight ahead, +deg toward LEFT arm, -deg toward
    RIGHT. Robust to coordinate orientation (signs itself from this trial's arm geometry)."""
    bl = np.degrees(np.arctan2(left_exit[1] - by, left_exit[0] - bx))
    br = np.degrees(np.arctan2(right_exit[1] - by, right_exit[0] - bx))
    mid = np.degrees(np.arctan2(np.sin(np.radians(bl)) + np.sin(np.radians(br)),
                                np.cos(np.radians(bl)) + np.cos(np.radians(br))))
    sgn = 1.0 if wrap(bl - mid) >= 0 else -1.0
    return sgn * wrap(az_deg - mid)

def _fig_trials(D):
    """Trials that belong on the junction FIGURES. Policy: ALWAYS drop
    invisible-from-perch blocked trials (they can bias the choice). Visible-blocked
    trials stay and are drawn like normal controls. JUNCTION_VIS, if set, applies
    as an extra restriction on top."""
    D = [d for d in D if d.get('vis') != 'invisible']
    if JUNCTION_VIS is not None:
        D = [d for d in D if d['vis'] in JUNCTION_VIS]
    return D

# ============================ FIGURES ============================
def _beam_dir_traces(D, transform):
    """Per (subject, side) binned beam+body traces vs time-to-arm. transform = _lat or _ang."""
    bins = np.arange(-2.0, 0.31, 0.15); bc = 0.5 * (bins[1:] + bins[:-1]); Wf = 25
    out = {}
    for d in D:
        subj = d.get('subject', '?')
        az, z, ct, bl, ti, idx = d['az'], d['zone'], d['ct'], d['bat'], d['ti'], d['idx']
        LE, RE = d['LEFT_exit'], d['RIGHT_exit']
        arm = np.isin(z, [4, 5]) & np.isfinite(ct); tr = ct - ct[arm].min()
        fin = np.isfinite(az); bvals = []; hvals = []; tvals = []
        for k in np.where(fin)[0]:
            bval = transform(az[k], bl[0, k], bl[1, k], LE, RE)
            fr = int(np.clip(idx[k], Wf, ti.shape[1] - Wf - 1)); v = ti[:, fr + Wf] - ti[:, fr - Wf]
            haz = np.degrees(np.arctan2(v[1], v[0])) if np.all(np.isfinite(v)) else np.nan
            hval = transform(haz, bl[0, k], bl[1, k], LE, RE) if np.isfinite(haz) else np.nan
            bvals.append(bval); hvals.append(hval); tvals.append(tr[k])
        bvals, hvals, tvals = map(np.array, (bvals, hvals, tvals))
        def binit(y):
            o = np.full(len(bc), np.nan)
            for bi in range(len(bc)):
                mm = (tvals >= bins[bi]) & (tvals < bins[bi + 1]) & np.isfinite(y)
                if mm.any(): o[bi] = np.nanmean(y[mm])
            return o
        s = out.setdefault(subj, {}).setdefault(d['side'], {'beam': [], 'head': []})
        s['beam'].append(binit(bvals)); s['head'].append(binit(hvals))
    return out, bc

def _plot_beam_dir(D, meta, transform, ylabel, title, fname):
    """Shared renderer for the two beam-direction figures. If D spans MULTIPLE subjects
    (ACROSS_SUBJECT), each bat is overlaid and distinguished by a marker (see the legend);
    with one subject it looks exactly like before. Invisible-blocked trials are excluded."""
    data, bc = _beam_dir_traces(_fig_trials(D), transform)
    mean = lambda A: np.nanmean(np.array(A), 0)
    sem = lambda A: np.nanstd(np.array(A), 0) / np.sqrt(np.maximum(1, np.sum(np.isfinite(np.array(A)), 0)))
    col = {'LEFT': '#2E86C1', 'RIGHT': '#E67E22'}
    subjects = sorted(data.keys()); multi = len(subjects) > 1
    markers = ['o', 's', '^', 'D', 'v', 'P']
    fig, A = plt.subplots(figsize=(9.6 if multi else 8.6, 5.8))
    A.axhline(0, color='#999', lw=.6); A.axvline(0, color='r', ls=':', lw=1.2)
    A.text(0.02, .015, 'enters arm', color='r', fontsize=8, transform=A.get_xaxis_transform())
    for si, subj in enumerate(subjects):
        mk = markers[si % len(markers)]
        for side in (BEAM_SIDES or ['LEFT', 'RIGHT']):
            if side not in data[subj] or not data[subj][side]['beam']: continue
            nb = len(data[subj][side]['beam'])
            mb = mean(data[subj][side]['beam']); mh = mean(data[subj][side]['head'])
            A.fill_between(bc, mb - sem(data[subj][side]['beam']), mb + sem(data[subj][side]['beam']), color=col[side], alpha=.10)
            if multi:
                A.plot(bc, mb, '-', marker=mk, color=col[side], lw=2.6, ms=4, label='%s beam (went %s, n=%d)' % (subj, side, nb))
                A.plot(bc, mh, '--', marker=mk, color=col[side], lw=1.8, ms=3, alpha=.9, label='%s body (went %s)' % (subj, side))
            else:
                A.plot(bc, mb, '-o', color=col[side], lw=2.9, ms=4, label='Beam direction  (went %s, n=%d)' % (side, nb))
                A.plot(bc, mh, '--', color=col[side], lw=2.0, alpha=.9, label='body direction  (went %s)' % side)
    A.set_xlim(-2, 0.3); A.set_xlabel('time relative to entering the arm (s)')
    A.set_ylabel(ylabel); A.set_title(title)
    A.legend(fontsize=7 if multi else 8, loc='upper left', ncol=2)
    if FIG_NOTE:
        fig.text(0.5, 0.005, FIG_NOTE, ha='center', va='bottom', fontsize=8, style='italic', color='#555')
    fig.tight_layout()
    out = os.path.join(meta['outdir'], fname)
    fig.savefig(out, dpi=130, bbox_inches='tight'); plt.close(fig); return out

def fig_junction_LR_split(D, meta):
    """BEAM (solid) + body HEADING (dashed) lateralization index vs time; blue=LEFT, orange=RIGHT.
    Solid beam separates from 0 before dashed body -> sonar leads the turn. Invisible-blocked
    trials excluded. Multiple subjects (ACROSS_SUBJECT) are overlaid, one marker per bat."""
    return _plot_beam_dir(D, meta, _lat,
        'beam lateralization  (+ left arm / − right arm)',
        'junction beam direction (n=%d sessions)' % len(meta['sessions']),
        '%s_%s_junction_LR_split.png' % (meta['subject'], meta['tag']))

def fig_junction_angle(D, meta):
    """Same as LR_split but y = direction in DEGREES from the maze midline (0 = straight ahead,
    + toward LEFT). Invisible-blocked trials excluded. Multiple subjects overlaid, marker per bat."""
    return _plot_beam_dir(D, meta, _ang,
        'beam / body direction  (° from midline;  + left / − right)',
        'junction beam direction  (° from straight-ahead, n=%d sessions)' % len(meta['sessions']),
        '%s_%s_junction_angle.png' % (meta['subject'], meta['tag']))

def fig_junction_predict_bar(D, meta):
    """Per-trial mean junction (JUNCTION_ZONE) beam lateralization; bar colored by the arm
    actually taken. Control + visible-blocked trials only (invisible-blocked excluded);
    block condition is NOT annotated here -- it lives in the database."""
    D = _fig_trials(D)
    rows = []
    for d in D:
        m = (d['zone'] == JUNCTION_ZONE) & np.isfinite(d['az'])
        if not m.any(): continue
        lat = np.nanmean([_lat(d['az'][k], d['bat'][0, k], d['bat'][1, k], d['LEFT_exit'], d['RIGHT_exit']) for k in np.where(m)[0]])
        rows.append((d['session'], d['trial'], d['side'], lat))
    rows.sort(key=lambda r: r[3])
    col = {'LEFT': '#2E86C1', 'RIGHT': '#E67E22'}
    fig, A = plt.subplots(figsize=(max(8, .32 * len(rows)), 4.6))
    A.bar(range(len(rows)), [r[3] for r in rows], color=[col[r[2]] for r in rows], edgecolor='k')
    A.axhline(0, color='k', lw=.8)
    if len(rows) <= 20:
        A.set_xticks(range(len(rows)))
        multi = len({r[0] for r in rows}) > 1
        A.set_xticklabels(['%s T%d' % (r[0][-4:], r[1]) if multi else 'T%d' % r[1] for r in rows], fontsize=7, rotation=90)
    else:
        A.set_xticks([])
    match = sum((r[3] > 0) == (r[2] == 'LEFT') for r in rows)
    A.set_ylabel('beam lateralization  (+ left arm / − right arm)')
    A.set_title('Junction beam and chosen arm\nbar color = arm actually taken  ·  %d/%d predict the chosen side' % (match, len(rows)))
    from matplotlib.patches import Patch
    leg = [Patch(color=col['LEFT'], label='went LEFT'), Patch(color=col['RIGHT'], label='went RIGHT')]
    A.legend(handles=leg, fontsize=8)
    fig.tight_layout()
    out = os.path.join(meta['outdir'], '%s_%s_junction_predict.png' % (meta['subject'], meta['tag']))
    fig.savefig(out, dpi=130, bbox_inches='tight'); plt.close(fig); return out

def fig_stat_table(D, meta):
    """Per-trial stat table (CSV) with condition labels + beam metrics. One row per trial;
    uses ALL trials (ignores the figure visibility policy). Lateralization: +1 toward LEFT
    arm, -1 toward RIGHT. This CSV mirrors the 'trials' table in the database.
    Three DISTINCT beam metrics per trial:
      preflight_lat = calls BEFORE take-off (idx <= takeoff; bat on perch)  -- visible trials matter here
      zone1_lat     = zone 1 'approach' calls (in-flight, near perch)       -- spatial zone, not pre-flight
      junction_lat  = zone JUNCTION_ZONE calls (the choice)                 -- invisible trials matter here"""
    import csv
    def _mask_lat(d, mask):
        m = mask & np.isfinite(d['az'])
        if not m.any(): return 0, np.nan
        v = [_lat(d['az'][k], d['bat'][0, k], d['bat'][1, k], d['LEFT_exit'], d['RIGHT_exit']) for k in np.where(m)[0]]
        return int(m.sum()), float(np.nanmean(v))
    _num = lambda x: '' if not np.isfinite(x) else round(x, 4)
    hdr = ['subject', 'session', 'trial', 'side_taken', 'blocked', 'block_side', 'visibility',
           'n_preflight_calls', 'preflight_lat', 'n_zone1_calls', 'zone1_lat',
           'n_junction_calls', 'junction_lat', 'junction_predicts_side']
    rows = []
    for d in D:
        npf, pf = _mask_lat(d, d['idx'] <= d['takeoff'])      # pre-flight: before take-off (on perch)
        nz1, z1 = _mask_lat(d, d['zone'] == 1)                # zone 1: approach (in-flight, near perch)
        njc, jc = _mask_lat(d, d['zone'] == JUNCTION_ZONE)    # junction: the choice
        pred = '' if not np.isfinite(jc) else int((jc > 0) == (d['side'] == 'LEFT'))
        rows.append([meta['subject'], d['session'], d['trial'], d['side'], int(d['blocked']),
                     (d.get('block_side') or ''), d['vis'],
                     npf, _num(pf), nz1, _num(z1), njc, _num(jc), pred])
    rows.sort(key=lambda r: (r[1], r[2]))
    out = os.path.join(meta['outdir'], '%s_%s_stat_table.csv' % (meta['subject'], meta['tag']))
    with open(out, 'w', newline='') as f:
        w = csv.writer(f); w.writerow(hdr); w.writerows(rows)
    return out

FIGURES = [fig_junction_LR_split, fig_junction_angle, fig_junction_predict_bar, fig_stat_table]   # <- add fig_*(D, meta) here

# ============================ DATABASE ===========================
def _db_records(D, meta):
    """Build (trial_rows, call_rows) for bp_db from the loaded trials D. Uses ALL
    trials (no figure filtering) so the database is the complete record."""
    ZK = getattr(B, 'ZONE_KEYS', ['approach', 'inside_y', 'past_y', 'arm_purple', 'arm_pink'])
    def zname(z):
        if not np.isfinite(z): return None
        z = int(z); return ZK[z - 1] if 1 <= z <= len(ZK) else None
    trial_rows = []; call_rows = []
    for d in D:
        az, el, z, ct, bl, idx = d['az'], d['el'], d['zone'], d['ct'], d['bat'], d['idx']
        LE, RE, tko = d['LEFT_exit'], d['RIGHT_exit'], d['takeoff']
        n = len(az); pf = idx <= tko
        for k in range(n):
            a = az[k]
            latk = _lat(a, bl[0, k], bl[1, k], LE, RE) if np.isfinite(a) else np.nan
            angk = _ang(a, bl[0, k], bl[1, k], LE, RE) if np.isfinite(a) else np.nan
            call_rows.append(dict(
                subject=meta['subject'], session=d['session'], trial=int(d['trial']),
                call_index=int(k), track_frame_idx=int(idx[k]) if np.isfinite(idx[k]) else None,
                call_time=_f(ct[k]), zone=int(z[k]) if np.isfinite(z[k]) else None, zone_name=zname(z[k]),
                bat_x=_f(bl[0, k]), bat_y=_f(bl[1, k]), bat_z=_f(bl[2, k]) if bl.shape[0] > 2 else None,
                beam_az_deg=_f(a), beam_el_deg=_f(el[k]),
                lat_index=_f(latk), angle_from_midline_deg=_f(angk),
                is_preflight=int(bool(pf[k])),
                is_zone1=int(z[k] == 1) if np.isfinite(z[k]) else 0,
                is_junction=int(z[k] == JUNCTION_ZONE) if np.isfinite(z[k]) else 0))

        def msk_lat(mask):
            m = mask & np.isfinite(az)
            if not m.any(): return 0, None
            v = [_lat(az[k], bl[0, k], bl[1, k], LE, RE) for k in np.where(m)[0]]
            return int(m.sum()), _f(np.nanmean(v))
        npf, pfl = msk_lat(idx <= tko)
        nz1, z1 = msk_lat(z == 1)
        njc, jc = msk_lat(z == JUNCTION_ZONE)
        pred = None if jc is None else int((jc > 0) == (d['side'] == 'LEFT'))
        trial_rows.append(dict(
            subject=meta['subject'], session=d['session'], trial=int(d['trial']),
            side_taken=d['side'], takeoff_frame=int(tko) if np.isfinite(tko) else None,
            n_preflight_calls=npf, preflight_lat=pfl, n_zone1_calls=nz1, zone1_lat=z1,
            n_junction_calls=njc, junction_lat=jc, junction_predicts_side=pred,
            blocked=int(bool(d['blocked'])), block_side=d.get('block_side'), visibility=d['vis']))
    return trial_rows, call_rows

def export_database(D, meta):
    """Write every trial + every call to the SQLite DB and refresh the flat mirror."""
    trial_rows, call_rows = _db_records(D, meta)
    bp_db.write_records(DB_PATH, trial_rows, call_rows)
    print('    [db] %d trials, %d calls  ->  %s' % (len(trial_rows), len(call_rows), DB_PATH))
    for m in bp_db.export_flat(DB_PATH, FLAT_DIR):
        print('    [db] mirror ', m)

def _make(subject, sessions, D):
    nL = sum(d['side'] == 'LEFT' for d in D); nR = sum(d['side'] == 'RIGHT' for d in D)
    if len(sessions) == 1:
        tag = sessions[0]; title = '%s %s' % (subject, sessions[0])
    else:
        tag = 'combined_' + '_'.join(s[-4:] for s in sessions); title = '%s  combined %s' % (subject, '+'.join(sessions))
    print('  %d arm-trials (went LEFT %d, went RIGHT %d)  ->  %s' % (len(D), nL, nR, tag))
    outdir = os.path.join(OUT_DIR, subject); os.makedirs(outdir, exist_ok=True)
    meta = dict(subject=subject, sessions=sessions, tag=tag, title=title, outdir=outdir)
    for figfn in FIGURES:
        print('    saved', figfn(D, meta))
    export_database(D, meta)

def run(subject, sessions, across_session):
    sessions = [sessions] if isinstance(sessions, str) else list(sessions)
    _merge_db_labels(subject, sessions)     # so batch runs tag trials without the form
    if across_session:                     # pool everything into one figure
        D = []
        for s in sessions:
            print('[%s %s] loading...' % (subject, s)); D += load_session(subject, s)
        _make(subject, sessions, D)
    else:                                   # one figure per session
        for s in sessions:
            print('[%s %s] loading...' % (subject, s)); _make(subject, [s], load_session(subject, s))

def run_multi(subjects, sessions, across_session):
    """ACROSS_SUBJECT: load each bat, write its data to the DB (per-subject, additive/safe),
    then draw ONE pair of beam-direction figures (LR_split + angle) with all bats overlaid
    (a marker per bat). Sessions are pooled per bat. Outputs go to 5_plot/_across_subjects/."""
    sessions = [sessions] if isinstance(sessions, str) else list(sessions)
    sesstag = sessions[0] if len(sessions) == 1 else 'combined_' + '_'.join(s[-4:] for s in sessions)
    D_all = []
    for subj in subjects:
        _merge_db_labels(subj, sessions)
        Ds = []
        for s in sessions:
            print('[%s %s] loading...' % (subj, s)); Ds += load_session(subj, s)
        D_all += Ds
        smeta = dict(subject=subj, sessions=sessions, tag=sesstag, title='%s %s' % (subj, sesstag),
                     outdir=os.path.join(OUT_DIR, subj)); os.makedirs(smeta['outdir'], exist_ok=True)
        export_database(Ds, smeta)          # DB stays per-subject -> never overwrites another bat
    meta = dict(subject='multibat', sessions=sessions, tag='%s_%s' % ('_'.join(subjects), sesstag),
                title='multibat', outdir=os.path.join(OUT_DIR, '_across_subjects'))
    os.makedirs(meta['outdir'], exist_ok=True)
    print('  overlay %d bats: %s' % (len(subjects), ', '.join(subjects)))
    print('    saved', fig_junction_LR_split(D_all, meta))
    print('    saved', fig_junction_angle(D_all, meta))

if __name__ == '__main__':
    if ACROSS_SUBJECT and SUBJECTS:
        run_multi(SUBJECTS, SESSIONS, ACROSS_SESSION)
    else:
        run(SUBJECT, SESSIONS, ACROSS_SESSION)
