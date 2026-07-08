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
- Creates a Derived Load Case combining all simulation steps automatically, per window
- Loops through all crank angle frames with a real-time Tkinter progress bar
- For each frame: queries Von Mises stress on every nodeset, tracks peak value + node ID + **simulation index** + crank angle label
- Exports per-frame CSV files (one subfolder per window) + one clean cross-window summary CSV

```
Input:  Selection Set IDs (space-separated, entered once, applied to every window)
Output: Win<id>/Stress_Frame001.csv ... Stress_FrameNNN.csv  (per crank angle, per window)
        Stress_Summary.csv   (one row per window × nodeset — WindowID, SetName,
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

1. Open HyperView with your simulation result loaded.
2. Open the Tcl console: `View → Command Window`.
3. Source the script:
   ```tcl
   source /path/to/TCL_StressExport.tcl
   ```
4. Enter Selection Set IDs when prompted (space-separated):
   ```
   => Enter selection set IDs: 1 2 3 4 5 6 7 8
   ```
5. Watch the progress bar — results export automatically to the script directory.

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
