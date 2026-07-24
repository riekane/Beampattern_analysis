#!/usr/bin/env python3
r"""
gen_notebook.py -- regenerate bp_figure_pipeline.ipynb from bp_figure_pipeline.py
Run from the 5_plot folder:  python gen_notebook.py
Keeps the .py as the single source of truth. Transforms applied for the notebook:
  os.path.dirname(os.path.abspath(__file__))  ->  os.getcwd()
  plt.close(fig)                              ->  plt.show()   (figures show inline)
and matplotlib is used inline (no 'Agg').
Cell layout (matches the original): markdown / imports / CONFIG / defs / form / run.
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.join(HERE, 'bp_figure_pipeline.py')
OUT  = os.path.join(HERE, 'bp_figure_pipeline.ipynb')

MARKDOWN = """# Beampattern figure pipeline

Notebook version (Python equivalent of a MATLAB live script).

**Workflow (run cells top to bottom):**
1. Edit the **CONFIG** cell (`SUBJECT`, `SESSIONS`, `ACROSS_SESSION`).
2. Run the code cell (defines everything).
3. Run the **Tag blocked trials** cell. A form lists that session's trials. Trials you have **already tagged are pre-filled from the database** (marked ✓ saved) — you only fill brand-new blank ones. Set **block side** (LEFT/RIGHT) and **perch view** (visible/invisible), then click **Save labels**.
4. Run the last cell to build the figures, the stat table, and update the database.

> The form is interactive, so **don't use \"Run All\"** — stop to fill it in, click Save, then run the final cell. Saved labels persist in `beampattern.db`, so next time they come back pre-filled.

Outputs go to `5_plot/`: per-subject junction figures (PNG) shown inline, a `<batID>_<tag>_stat_table.csv`, plus **one `beampattern.db` (SQLite) and a Parquet/CSV mirror** (`beampattern_trials.*`, `beampattern_calls.*`) holding every trial and every call — queryable from Python and from MATLAB (`parquetread`, no toolbox).

*Figure policy:* **invisible**-from-perch blocked trials are excluded from the junction figures (they can bias the choice); **visible**-from-perch blocked trials stay and look like normal controls (they only affect the pre-flight call). Both are still recorded in the database. Requires `beamlib.py` + `h5read.py` + `bp_db.py` here; run from `5_plot`."""

IMPORTS = "import os, sys, glob, re\nimport numpy as np\nimport matplotlib.pyplot as plt\n%matplotlib inline"

FORM = """# ===== Tag blocked trials (popup form) =====
# A form appears below listing every trial in the sessions you set above.
# Trials you have ALREADY tagged are PRE-FILLED from the database (marked ✓ saved) --
# you only need to fill brand-new blank ones. For each blocked trial pick the
# BLOCK SIDE (LEFT/RIGHT) and the PERCH VIEW (visible / invisible), then click
# 'Save labels' (writes to beampattern.db). Leave normal trials as '—'/'normal'.
# After saving, run the final cell to build the figures + stat table + database.
label_trials()"""

RUN = ("if ACROSS_SUBJECT and SUBJECTS:\n"
       "    run_multi(SUBJECTS, SESSIONS, ACROSS_SESSION)\n"
       "else:\n"
       "    run(SUBJECT, SESSIONS, ACROSS_SESSION)")

CONFIG_MARK = '# ======================= CONFIG'
DEFS_MARK   = 'sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))'
MAIN_MARK   = "if __name__ == '__main__':"


def code_cell(src):
    return {"cell_type": "code", "execution_count": None, "metadata": {},
            "outputs": [], "source": src.splitlines(keepends=True)}

def md_cell(src):
    return {"cell_type": "markdown", "metadata": {}, "source": src.splitlines(keepends=True)}


def main():
    src = open(SRC, 'r', encoding='utf-8').read()
    i_cfg, i_def, i_main = src.index(CONFIG_MARK), src.index(DEFS_MARK), src.index(MAIN_MARK)
    config_src = src[i_cfg:i_def].rstrip('\n')
    defs_src   = src[i_def:i_main].rstrip('\n')
    defs_src = defs_src.replace('os.path.dirname(os.path.abspath(__file__))', 'os.getcwd()')
    defs_src = defs_src.replace('plt.close(fig)', 'plt.show()')

    nb = {"cells": [md_cell(MARKDOWN), code_cell(IMPORTS), code_cell(config_src),
                    code_cell(defs_src), code_cell(FORM), code_cell(RUN)],
          "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
                       "language_info": {"name": "python", "pygments_lexer": "ipython3"}},
          "nbformat": 4, "nbformat_minor": 5}
    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump(nb, f, indent=1, ensure_ascii=False)
    print('wrote', OUT, '(%d cells)' % len(nb['cells']))


if __name__ == '__main__':
    main()
