# MaxStress_Panel.tcl — button panel ("add-in") for the Max Stress tools.
#
# Load inside HyperView:   source <path>/MaxStress_Panel.tcl
# Or auto-open at startup: hw.exe <model> -tcl <path>/MaxStress_Panel.tcl
#
# The panel is a floating always-on-top window. All logic lives in
# maxstress_lib.tcl; this file is UI only.

source [file join [file dirname [file normalize [info script]]] maxstress_lib.tcl]

package require Tk

namespace eval ::MaxStressPanel {
    variable W .maxstressPanel
}

proc ::MaxStressPanel::SetStatus {msg {color black}} {
    variable W
    $W.status configure -text $msg -foreground $color
    update idletasks
}

proc ::MaxStressPanel::DoExport {} {
    variable W
    set ids [split [string trim [$W.exp.ids get]]]
    if {[llength $ids] == 0} {
        SetStatus "Enter selection set IDs first." red
        return
    }
    SetStatus "Export running..." blue
    if {[catch {::MaxStress::RunExport $ids} result]} {
        SetStatus "Export FAILED: $result" red
    } else {
        LoadResults
        SetStatus "Export done -> $result" darkgreen
    }
}

# Fill the results table from Stress_Summary.csv
# (columns: WindowID,SetName,MaxNodeID,MaxStressValue_MPa,SimulationID,CrankAngle_deg,SimulationLabel)
proc ::MaxStressPanel::LoadResults {} {
    variable W
    set csvFile [file join $::MaxStress::LIB_DIR "Stress_Summary.csv"]

    $W.res.tv delete [$W.res.tv children {}]

    if {![file exists $csvFile]} {
        SetStatus "No CSV yet — run Export first." red
        return
    }
    set f [open $csvFile r]
    set lineNo 0
    set n 0
    while {[gets $f line] >= 0} {
        incr lineNo
        if {$lineNo == 1} { continue }
        if {[string trim $line] eq ""} { continue }
        set fields [split $line ","]
        if {[llength $fields] < 6} { continue }
        lassign $fields rWin rSetName rNodeID rStress rSimID rAngle
        set stress3 ""
        catch {set stress3 [format "%.3f" $rStress]}
        $W.res.tv insert {} end -values [list $rWin $rSetName $rNodeID $stress3 $rAngle]
        incr n
    }
    close $f
    SetStatus "Results table: $n row(s) loaded." darkgreen
}

proc ::MaxStressPanel::DoAnnotate {} {
    variable W
    set setID [string trim [$W.ann.id get]]
    if {$setID eq ""} {
        SetStatus "Enter one selection set ID first." red
        return
    }
    SetStatus "Annotating set $setID..." blue
    if {[catch {::MaxStress::RunAnnotate $setID} result]} {
        SetStatus "Annotate FAILED: $result" red
    } else {
        SetStatus "Annotate done (set $setID)." darkgreen
    }
}

proc ::MaxStressPanel::Build {} {
    variable W

    catch {destroy $W}
    toplevel $W
    wm title $W "Max Stress Tools — Nguyen Tan Loc"
    wm attributes $W -topmost 1
    wm resizable $W 0 1     ;# vertically resizable for the results table

    # ── Export section ──
    labelframe $W.exp -text " 1. Max Stress Export (all windows) " -padx 8 -pady 6
    label  $W.exp.lbl -text "Selection set IDs (space-separated):"
    entry  $W.exp.ids -width 32
    button $W.exp.run -text "Run Export" -width 14 -command ::MaxStressPanel::DoExport
    grid $W.exp.lbl -row 0 -column 0 -sticky w
    grid $W.exp.ids -row 1 -column 0 -sticky we -pady 2
    grid $W.exp.run -row 1 -column 1 -padx {6 0}
    pack $W.exp -fill x -padx 10 -pady {10 4}

    # ── Annotate section ──
    labelframe $W.ann -text " 2. Annotate Max Stress (from CSV) " -padx 8 -pady 6
    label  $W.ann.lbl -text "One selection set ID:"
    entry  $W.ann.id -width 12
    button $W.ann.run -text "Annotate" -width 14 -command ::MaxStressPanel::DoAnnotate
    grid $W.ann.lbl -row 0 -column 0 -sticky w
    grid $W.ann.id  -row 1 -column 0 -sticky w -pady 2
    grid $W.ann.run -row 1 -column 1 -padx {6 0}
    pack $W.ann -fill x -padx 10 -pady 4

    # ── Options section ──
    labelframe $W.opt -text " Options " -padx 8 -pady 6
    label $W.opt.l1 -text "Marker size:"
    entry $W.opt.mea -width 5 -textvariable ::MaxStress::MEA_FSIZE
    label $W.opt.l2 -text "Note size:"
    entry $W.opt.note -width 5 -textvariable ::MaxStress::NOTE_FSIZE
    label $W.opt.l3 -text "Color (R G B):"
    entry $W.opt.color -width 12 -textvariable ::MaxStress::PINK
    grid $W.opt.l1    -row 0 -column 0 -sticky w
    grid $W.opt.mea   -row 0 -column 1 -sticky w -padx {4 12}
    grid $W.opt.l2    -row 0 -column 2 -sticky w
    grid $W.opt.note  -row 0 -column 3 -sticky w -padx {4 0}
    grid $W.opt.l3    -row 1 -column 0 -sticky w -pady {4 0}
    grid $W.opt.color -row 1 -column 1 -columnspan 3 -sticky w -padx {4 0} -pady {4 0}
    pack $W.opt -fill x -padx 10 -pady 4

    # ── Results table (all windows) ──
    labelframe $W.res -text " 3. Results — all windows " -padx 8 -pady 6
    ttk::treeview $W.res.tv -columns {win set node stress angle} -show headings -height 9 \
        -yscrollcommand [list $W.res.sb set]
    $W.res.tv heading win    -text "Win"
    $W.res.tv heading set    -text "Set"
    $W.res.tv heading node   -text "Node ID"
    $W.res.tv heading stress -text "Max Stress (MPa)"
    $W.res.tv heading angle  -text "Angle"
    $W.res.tv column win    -width 40  -anchor center
    $W.res.tv column set    -width 80  -anchor w
    $W.res.tv column node   -width 90  -anchor center
    $W.res.tv column stress -width 110 -anchor e
    $W.res.tv column angle  -width 90  -anchor center
    scrollbar $W.res.sb -orient vertical -command [list $W.res.tv yview]
    button $W.res.refresh -text "Refresh from CSV" -command ::MaxStressPanel::LoadResults
    grid $W.res.tv      -row 0 -column 0 -sticky nswe
    grid $W.res.sb      -row 0 -column 1 -sticky ns
    grid $W.res.refresh -row 1 -column 0 -sticky w -pady {4 0}
    grid columnconfigure $W.res 0 -weight 1
    pack $W.res -fill both -expand 1 -padx 10 -pady 4

    # ── Status bar ──
    label $W.status -text "Ready." -anchor w -relief sunken -padx 6
    pack $W.status -fill x -side bottom -padx 10 -pady {4 10}

    # Pre-fill the table if a CSV from a previous run exists
    catch {LoadResults}
}

::MaxStressPanel::Build
puts "Max Stress panel loaded — window '[wm title $::MaxStressPanel::W]' is open."
