# Von Mises Stress Sweep Exporter — HyperView Tcl

Automated post-processing for **AVL EXCITE Power Unit** results inside **Altair HyperView**.
Tracks **maximum Von Mises stress** across all crank angle frames for multiple nodesets simultaneously, with a real-time Tk progress bar.

**Author:** Nguyen Tan Loc — Simulation Engineer
**Context:** EHD simulation support · conrod and piston stress analysis

---

## The problem it solves

For each component spec: switch frame → drag-select region → query max stress → note value + node ID → move to next frame → compare across all frames to find worst case.

- 34 frames per job (15 combustion + 19 inertia)
- 8 component specs per analysis
- ~2 hours per spec manually = **16 hours total**

## What it does

- **Loops over every window on the active page** (not just the active one) —
  each window gets its own Derived Load Case + frame sweep, since separate
  windows can hold independent models/result files (e.g. an 8-up crank-angle
  comparison layout)
- Creates a Derived Load Case combining all crank-angle simulation steps
  automatically, per window (bolt-tightening steps and other windows'
  derived cases are excluded by label pattern)
- Loops through all crank angle frames with a real-time Tkinter progress bar
- For each frame: queries Von Mises stress on every nodeset, tracks peak value + node ID + **simulation index** + crank angle label
- Exports **one single summary CSV** covering every window × nodeset

```
Input:  Selection Set IDs (space-separated, entered once, applied to every window)
Output: Stress_Summary.csv   (one row per window × nodeset — WindowID, SetName,
                               MaxNodeID, MaxStressValue_MPa, SimulationID,
                               CrankAngle_deg, SimulationLabel)
```

---

## Time saved

| Task | Manual | Script |
|------|--------|--------|
| 1 spec × 34 frames | ~2 hours | ~1 minute |
| 8 specs (full job) | ~16 hours | ~8 minutes |
| Error rate | High (manual transcription) | Zero |

---

## How to run

### Option A0 — combined tabbed panel (Max Stress + Safety Factor)

```tcl
source /path/to/HVTools_Panel.tcl
```
One panel, HyperView-style tabs: shared **0. Load model & results** section
on top (model path + one result file per window + layout, auto-load on open
from the saved config), then a **Max Stress** tab and a **Safety Factor**
tab, each with its own Export / Annotate / Options / editable Results table.
Requires `maxstress_lib.tcl` (this repo) and — for the SF tab —
`safetyfactor_lib.tcl` copied from
[Tcl_Safety-Factor-](https://github.com/NeuJin/Tcl_Safety-Factor-) into the
same folder (the SF tab shows a hint and stays inert if it's missing).

### Option A — button panel (recommended)

```tcl
source /path/to/MaxStress_Panel.tcl
```
A floating **Max Stress Tools** panel opens with an Export section, an
Annotate section and options (marker/note text size, marker color). To have
the panel open automatically, launch HyperView with:
```
hw.exe <model_or_session> -tcl /path/to/MaxStress_Panel.tcl
```

### Option B — console scripts

1. Open HyperView with your simulation result loaded.
2. Open the Tcl console: `View → Command Window`.
3. Source the script:
   ```tcl
   source /path/to/TCL_StressExport.tcl        ;# max-stress sweep → CSV
   source /path/to/TCL_MaxStressAnnotate.tcl   ;# markers + notes from CSV
   ```
4. Enter Selection Set IDs when prompted (space-separated):
   ```
   => Enter selection set IDs: 1 2 3 4 5 6 7 8
   ```
5. Watch the progress bar — results export automatically to the script directory.

### File layout

| File | Role |
|------|------|
| `maxstress_lib.tcl` | All logic (procs, no UI) — sourced by everything below |
| `MaxStress_Panel.tcl` | Floating button panel (add-in style) |
| `TCL_StressExport.tcl` | Console wrapper: prompt → `::MaxStress::RunExport` |
| `TCL_MaxStressAnnotate.tcl` | Console wrapper: prompt → `::MaxStress::RunAnnotate` |

---

## Requirements

- Altair HyperView (tested with HyperWorks 2021+)
- AVL EXCITE Power Unit result files loaded
- Selection Sets pre-defined in the model (nodesets per component spec)
- Tcl/Tk (bundled with HyperWorks — no separate install needed)

---

## Companion tool

For per-nodeset Safety Factor extraction (Load Case 1), see
**[Tcl_Safety-Factor-](https://github.com/NeuJin/Tcl_Safety-Factor-)** — the two scripts together cover the full post-processing pipeline from raw solver output to report-ready data.

---

## Author

**Nguyen Tan Loc** — Simulation Engineer
Technostar Co., Ltd (Outsourced to Suzuki Motor Corporation)
[LinkedIn](https://linkedin.com/in/nguyentanloc-cae)

*Previously: Bosch Global Software Technologies Vietnam · Datbike EV Startup*
