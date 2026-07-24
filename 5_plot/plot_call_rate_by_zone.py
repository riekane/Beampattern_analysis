#!/usr/bin/env python3
r"""
CALL RATE BY MAZE ZONE  --  single-bat bar chart + two-bat line plot
====================================================================
Reads *_bp_proc.mat, computes call rate in each maze zone using ALL detected
calls (drop-out robust), and plots mean +/- SEM across trials.

Why "all detected calls": proc/call_receive_time holds only calls that were
localised (they need a Vicon 3D position). ~50% of detected calls have no track
and are dropped -- concentrated at the fast turn into the arm -- which would
undercount the rate there. Instead we take each zone's time-window (from the
tracked calls) and count EVERY detected call inside it
(mic_data/call/call_start_idx / fs), so the rate is not biased by tracking loss.
(For the zone-window method this barely differs from tracked-only, which is the
check that it is unbiased.)

Run:   python plot_call_rate_by_zone.py
Needs: numpy, matplotlib, beamlib.py, h5read.py  (already in 5_plot). No MATLAB.
Paths auto-detect (Windows Z:\ or mounted Linux path). PNGs saved into 5_plot.
"""
import os, sys, glob, re
import numpy as np
import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt

# ============================ CONFIG -- EDIT THESE ============================
# One entry per bat. 'invisible_block' trials are DROPPED (an unseen block can
# bias the flight/choice); visible-block trials are kept -- same policy as
# bp_figure_pipeline.py. Colours are used for both figures.
BATS = {
    'batA125': dict(
        color    = '#2b6cb0',
        sessions = ['20260710', '20260714', '20260720'],
        invisible_block = {'20260714': [5, 7, 8, 10, 11, 13, 14, 15]},
    ),
    'batFB80': dict(
        color    = '#d55e00',
        sessions = ['20260703', '20260714', '20260720'],
        invisible_block = {'20260714': [6, 7, 8, 9, 10, 11, 12, 13, 14]},
    ),
}
# maze zone ids (beamlib): 1 approach, 2 stem, 3 junction, 4 LEFT arm, 5 RIGHT arm
CATS_SPLIT  = [('pre-maze entrance', [1]), ('Y-maze stem', [2]), ('Y-maze junction', [3]),
               ('left arm', [4]), ('right arm', [5])]        # single-bat bar chart
CATS_POOLED = [('pre-maze entrance', [1]), ('Y-maze stem', [2]), ('Y-maze junction', [3]),
               ('arm (L/R)', [4, 5])]                        # two-bat line (pool arms)
# =============================================================================

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import beamlib as B

def _pick(cands):
    for c in cands:
        if c and os.path.isdir(c): return c
    return cands[0]
BP_ROOT = _pick([r'Z:\Rie\Data\Beampattern_proc'] + sorted(glob.glob('/sessions/*/mnt/Beampattern_proc')))
OUT_DIR = _pick([r'Z:\Rie\Analysis\Beampattern_analysis\5_plot'] +
                sorted(glob.glob('/sessions/*/mnt/5_plot')) + [os.path.dirname(os.path.abspath(__file__))])

def _rd(h, p):
    try:
        a = h.read(p); return None if a is None else np.asarray(a)
    except Exception:
        return None

def _deref(h, p):
    """First element of every cell in a cell-array field (e.g. call_start_idx)."""
    dims, addrs = h.read_refs(p); out = []
    for ad in addrs:
        ad = int(ad)
        if not ad: out.append(np.nan); continue
        v = h.read_dataset(h.ub + ad); a = np.asarray(v).ravel() if v is not None else np.array([])
        out.append(float(a[0]) if a.size else np.nan)
    return np.array(out)

def zone_rates(subject, cats):
    """-> dict cat_name -> list of per-trial call rate (Hz), one value per trial per zone."""
    cfg = BATS[subject]; invis = cfg.get('invisible_block', {})
    per = {c[0]: [] for c in cats}
    bp_dir = os.path.join(BP_ROOT, subject, 'beampattern_output')
    for date in cfg['sessions']:
        for f in sorted(glob.glob(os.path.join(bp_dir, f'{date}_T*_*bp_proc.mat'))):
            tn = int(re.search(r'_T0*([0-9]+)_', os.path.basename(f)).group(1))
            if tn in invis.get(date, []):                       # drop invisible-block trials
                continue
            h   = B.open_trial(f)
            ct  = _rd(h, 'proc/call_receive_time')
            z   = _rd(h, 'proc/beam_zone_id')
            ciw = _rd(h, 'mic_data/call_idx_w_track')
            if ct is None or z is None or ciw is None: continue
            ct = ct.ravel(); z = z.ravel(); ciw = ciw.ravel().astype(int)
            fs  = float(np.asarray(_rd(h, 'mic_data/fs')).ravel()[0])
            csi = _deref(h, 'mic_data/call/call_start_idx')     # sample idx of EVERY detected call
            try:                                                # align detected clock to receive-time clock
                off = np.nanmedian(ct - (csi / fs)[ciw - 1])
            except Exception:
                continue
            det = np.sort(csi / fs + off)                       # ALL detected call times (s)
            for nm, zs in cats:
                m = np.isin(z, zs) & np.isfinite(ct)
                if m.sum() < 3: continue
                t0, t1 = ct[m].min(), ct[m].max()               # this zone's time-window (from tracked calls)
                if t1 - t0 < 0.08: continue
                dd = det[(det >= t0) & (det <= t1)]             # every detected call inside the window
                ici = np.diff(dd); ici = ici[(ici > 0) & (ici < 2)]
                if ici.size >= 2:
                    per[nm].append(1.0 / np.median(ici))        # rate = 1 / median inter-call interval
    return per

def _mean_sem(per, cats):
    m, s, n = [], [], []
    for nm, _ in cats:
        a = np.array(per[nm])
        m.append(a.mean() if a.size else np.nan)
        s.append(a.std(ddof=1) / np.sqrt(a.size) if a.size > 1 else 0.0)
        n.append(int(a.size))
    return np.array(m), np.array(s), n

def _lab(c):    # 'pre-maze entrance' -> two lines
    return c.replace(' ', '\n', 1)

# ------------------------------ FIGURES ------------------------------
plt.rcParams.update({'font.size': 12, 'axes.spines.top': False,
                     'axes.spines.right': False, 'figure.dpi': 150})

def fig_single(subject):
    per = zone_rates(subject, CATS_SPLIT); m, s, n = _mean_sem(per, CATS_SPLIT)
    col = BATS[subject]['color']; x = np.arange(len(CATS_SPLIT))
    fig, ax = plt.subplots(figsize=(8.2, 5.2))
    ax.bar(x, m, yerr=s, color=col, width=0.66, capsize=5, error_kw=dict(lw=1.6, ecolor='#222'))
    for i in range(len(x)):
        if np.isfinite(m[i]):
            ax.text(x[i], m[i] + s[i] + 1.0, f'{m[i]:.0f}', ha='center', fontweight='bold', color=col, fontsize=11)
            ax.text(x[i], 1.0, f'n={n[i]}', ha='center', color='white' if m[i] > 6 else '#555', fontsize=8.5)
    ax.set_xticks(x); ax.set_xticklabels([_lab(c[0]) for c in CATS_SPLIT])
    ax.set_ylabel('call rate  (Hz,  1 / median inter-call interval)')
    ax.set_title(f'Call rate across the trial — {subject}', fontweight='bold', loc='left')
    fig.tight_layout()
    out = os.path.join(OUT_DIR, f'{subject}_call_rate_by_zone.png')
    fig.savefig(out, bbox_inches='tight', facecolor='white'); plt.close(fig); print('saved', out)

def fig_two_bats(subjects):
    fig, ax = plt.subplots(figsize=(8.4, 5.4)); x = np.arange(len(CATS_POOLED))
    offs = np.linspace(-0.06, 0.06, len(subjects)) if len(subjects) > 1 else [0.0]
    for subj, dx in zip(subjects, offs):
        per = zone_rates(subj, CATS_POOLED); m, s, n = _mean_sem(per, CATS_POOLED)
        ax.errorbar(x + dx, m, yerr=s, color=BATS[subj]['color'], lw=2.2, marker='o', ms=8,
                    capsize=5, elinewidth=1.6, mec='white', mew=1, label=subj)
    ax.set_xticks(x); ax.set_xticklabels([_lab(c[0]) for c in CATS_POOLED])
    ax.set_ylabel('call rate  (Hz,  1 / median inter-call interval)')
    ax.set_title('Call rate across the trial', fontweight='bold', loc='left')
    ax.legend(frameon=False, fontsize=12, loc='upper left')
    fig.tight_layout()
    out = os.path.join(OUT_DIR, 'call_rate_by_zone_2bats.png')
    fig.savefig(out, bbox_inches='tight', facecolor='white'); plt.close(fig); print('saved', out)

if __name__ == '__main__':
    for subj in BATS:
        fig_single(subj)
    fig_two_bats(list(BATS.keys()))
    print('done ->', OUT_DIR)
