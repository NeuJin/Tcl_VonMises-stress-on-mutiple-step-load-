# HVTools_Panel.tcl — combined add-in panel: Max Stress + Safety Factor.
#
# Layout: shared "0. Load model & results" section on top, then a tabbed
# notebook (like HyperView's own Session/Results tabs):
#   Tab "Max Stress"    — export / annotate / options / results table
#   Tab "Safety Factor" — export / annotate / options / results table
#
# Requires maxstress_lib.tcl in the SAME folder. safetyfactor_lib.tcl
# (from the Tcl_Safety-Factor- repo) must also be copied into this folder
# for the SF tab — without it the SF tab is disabled.
#
# Load inside HyperView:   source <path>/HVTools_Panel.tcl
# Or auto-open at startup: hw.exe <model> -tcl <path>/HVTools_Panel.tcl

set _dir [file dirname [file normalize [info script]]]
source [file join $_dir maxstress_lib.tcl]
namespace eval ::HVTools {
    variable HAS_SF 0
}
if {[file exists [file join $_dir safetyfactor_lib.tcl]]} {
    source [file join $_dir safetyfactor_lib.tcl]
    set ::HVTools::HAS_SF 1
}

package require Tk

namespace eval ::HVTools {
    variable W  .hvtools
    variable MS ""
    variable SF ""
    variable CONFIG [file join $::MaxStress::LIB_DIR "maxstress_config.txt"]
}

proc ::HVTools::SetStatus {msg {color black}} {
    variable W
    $W.status configure -text $msg -foreground $color
    update idletasks
}

# ═════════════════════════ Load section ═════════════════════════

proc ::HVTools::SaveConfig {modelFile cols rows resultFiles} {
    variable CONFIG
    catch {
        set f [open $CONFIG w]
        puts $f $modelFile
        puts $f "$cols $rows"
        foreach rf $resultFiles { puts $f $rf }
        close $f
    }
}

proc ::HVTools::LoadConfig {} {
    variable CONFIG
    if {![file exists $CONFIG]} { return "" }
    set f [open $CONFIG r]
    set lines {}
    while {[gets $f line] >= 0} {
        if {[string trim $line] ne ""} { lappend lines $line }
    }
    close $f
    if {[llength $lines] < 3} { return "" }
    set modelFile [lindex $lines 0]
    lassign [lindex $lines 1] cols rows
    set resultFiles [lrange $lines 2 end]
    return [list $modelFile $cols $rows $resultFiles]
}

proc ::HVTools::BrowseModel {} {
    variable W
    set f [tk_getOpenFile -title "Select model file" \
        -filetypes {{"Model files" {.inp .fem .key .dyn}} {"All files" *}}]
    if {$f ne ""} {
        $W.load.model delete 0 end
        $W.load.model insert 0 $f
    }
}

proc ::HVTools::BrowseResults {} {
    variable W
    set files [tk_getOpenFile -title "Select result file(s)" -multiple 1 \
        -filetypes {{"Result files" {.odb .res .op2 .h3d}} {"All files" *}}]
    foreach f $files {
        $W.load.res insert end "$f\n"
    }
}

proc ::HVTools::ReadLoadFields {} {
    variable W
    set modelFile [string trim [$W.load.model get]]
    set cols [string trim [$W.load.cols get]]
    set rows [string trim [$W.load.rows get]]
    set resultFiles {}
    foreach line [split [$W.load.res get 1.0 end] "\n"] {
        set line [string trim $line]
        if {$line ne ""} { lappend resultFiles $line }
    }
    return [list $modelFile $cols $rows $resultFiles]
}

proc ::HVTools::DoLoadAll {} {
    lassign [ReadLoadFields] modelFile cols rows resultFiles
    if {$modelFile eq ""} {
        SetStatus "Enter the model file path first." red
        return
    }
    if {[llength $resultFiles] == 0} {
        SetStatus "Enter at least one result file path." red
        return
    }
    if {![string is integer -strict $cols] || ![string is integer -strict $rows]} {
        SetStatus "Layout must be two integers (e.g. 4 x 2)." red
        return
    }
    SetStatus "Loading [llength $resultFiles] result(s) into ${cols}x${rows} layout..." blue
    if {[catch {::MaxStress::LoadAll $modelFile $resultFiles $cols $rows} result]} {
        SetStatus "Load FAILED: $result" red
    } else {
        SaveConfig $modelFile $cols $rows $resultFiles
        SetStatus "Loaded [llength $resultFiles] result(s) into $result window(s)." darkgreen
    }
}

# ═════════════════════════ Max Stress tab ═════════════════════════

proc ::HVTools::MSExport {} {
    variable MS
    set ids [split [string trim [$MS.exp.ids get]]]
    if {[llength $ids] == 0} {
        SetStatus "Enter selection set IDs first." red
        return
    }
    SetStatus "Max Stress export running..." blue
    if {[catch {::MaxStress::RunExport $ids} result]} {
        SetStatus "Export FAILED: $result" red
    } else {
        MSLoadResults
        SetStatus "Export done -> $result" darkgreen
    }
}

proc ::HVTools::MSAnnotate {} {
    variable MS
    set setID [string trim [$MS.ann.id get]]
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

proc ::HVTools::MSLoadResults {} {
    variable MS
    set csvFile [file join $::MaxStress::LIB_DIR "Stress_Summary.csv"]
    $MS.res.tv delete [$MS.res.tv children {}]
    if {![file exists $csvFile]} {
        SetStatus "No stress CSV yet — run Export first." red
        return
    }
    set f [open $csvFile r]
    set lineNo 0 ; set n 0
    while {[gets $f line] >= 0} {
        incr lineNo
        if {$lineNo == 1 || [string trim $line] eq ""} { continue }
        set fields [split $line ","]
        if {[llength $fields] < 6} { continue }
        lassign $fields rWin rSetName rNodeID rStress rSimID rAngle
        set stress3 ""
        catch {set stress3 [format "%.3f" $rStress]}
        $MS.res.tv insert {} end -values [list $rWin $rSetName $rNodeID $stress3 $rAngle]
        incr n
    }
    close $f
    SetStatus "Stress results: $n row(s) loaded." darkgreen
}

proc ::HVTools::MSOnSelect {} {
    variable MS
    set sel [$MS.res.tv selection]
    if {[llength $sel] == 0} { return }
    lassign [$MS.res.tv item [lindex $sel 0] -values] rWin rSet rNode rStress rAngle
    $MS.res.node delete 0 end ; $MS.res.node insert 0 $rNode
    $MS.res.ang  delete 0 end ; $MS.res.ang  insert 0 $rAngle
}

proc ::HVTools::MSRequery {} {
    variable MS
    set sel [$MS.res.tv selection]
    if {[llength $sel] == 0} {
        SetStatus "Select a row in the table first." red
        return
    }
    set item [lindex $sel 0]
    lassign [$MS.res.tv item $item -values] rWin rSet oldNode oldStress oldAngle
    set newNode  [string trim [$MS.res.node get]]
    set newAngle [string trim [$MS.res.ang get]]
    if {$newNode eq "" || $newAngle eq ""} {
        SetStatus "Enter Node ID and Angle first." red
        return
    }
    SetStatus "Re-querying win $rWin node $newNode @ $newAngle ..." blue
    if {[catch {::MaxStress::QueryNodeValue $rWin $newNode $newAngle} result]} {
        SetStatus "Re-query FAILED: $result" red
        return
    }
    lassign $result val simIdx simLabel angleStr
    set stress3 [format "%.3f" $val]
    $MS.res.tv item $item -values [list $rWin $rSet $newNode $stress3 $angleStr]
    MSUpdateCsv $rWin $rSet $newNode $val $simIdx $angleStr $simLabel
    SetStatus "Win $rWin / $rSet -> node $newNode @ $angleStr = $stress3 MPa (CSV updated)" darkgreen
}

proc ::HVTools::MSUpdateCsv {rWin rSet nodeID val simIdx angleStr simLabel} {
    set csvFile [file join $::MaxStress::LIB_DIR "Stress_Summary.csv"]
    if {![file exists $csvFile]} { return }
    set f [open $csvFile r]
    set lines {}
    while {[gets $f line] >= 0} { lappend lines $line }
    close $f
    set out {}
    foreach line $lines {
        set fields [split $line ","]
        if {[llength $fields] >= 6 && [lindex $fields 0] == $rWin && [lindex $fields 1] eq $rSet} {
            lappend out "$rWin,$rSet,$nodeID,[format "%.8f" $val],$simIdx,$angleStr,\"$simLabel\""
        } else {
            lappend out $line
        }
    }
    set f [open $csvFile w]
    foreach line $out { puts $f $line }
    close $f
}

# ═════════════════════════ Safety Factor tab ═════════════════════════

proc ::HVTools::SFExport {} {
    variable SF
    set ids [split [string trim [$SF.exp.ids get]]]
    if {[llength $ids] == 0} {
        SetStatus "Enter selection set IDs (or names) first." red
        return
    }
    SetStatus "Safety Factor export running..." blue
    if {[catch {::SafetyFactor::RunExport $ids} result]} {
        SetStatus "Export FAILED: $result" red
    } else {
        SFLoadResults
        SetStatus "Export done -> $result" darkgreen
    }
}

proc ::HVTools::SFAnnotate {} {
    variable SF
    set setID [string trim [$SF.ann.id get]]
    if {$setID eq ""} {
        SetStatus "Enter one selection set ID first." red
        return
    }
    SetStatus "Annotating set $setID..." blue
    if {[catch {::SafetyFactor::RunAnnotate $setID} result]} {
        SetStatus "Annotate FAILED: $result" red
    } else {
        SetStatus "Annotate done (set $setID)." darkgreen
    }
}

proc ::HVTools::SFLoadResults {} {
    variable SF
    set csvFile [file join $::SafetyFactor::LIB_DIR "SafetyFactor_Summary.csv"]
    $SF.res.tv delete [$SF.res.tv children {}]
    if {![file exists $csvFile]} {
        SetStatus "No SF CSV yet — run Export first." red
        return
    }
    set f [open $csvFile r]
    set lineNo 0 ; set n 0
    while {[gets $f line] >= 0} {
        incr lineNo
        if {$lineNo == 1 || [string trim $line] eq ""} { continue }
        set fields [split $line ","]
        if {[llength $fields] < 4} { continue }
        lassign $fields rWin rSetName rNodeID rSF
        set sf3 ""
        catch {set sf3 [format "%.3f" $rSF]}
        $SF.res.tv insert {} end -values [list $rWin $rSetName $rNodeID $sf3]
        incr n
    }
    close $f
    SetStatus "SF results: $n row(s) loaded." darkgreen
}

proc ::HVTools::SFOnSelect {} {
    variable SF
    set sel [$SF.res.tv selection]
    if {[llength $sel] == 0} { return }
    lassign [$SF.res.tv item [lindex $sel 0] -values] rWin rSet rNode rSF
    $SF.res.node delete 0 end ; $SF.res.node insert 0 $rNode
}

proc ::HVTools::SFRequery {} {
    variable SF
    set sel [$SF.res.tv selection]
    if {[llength $sel] == 0} {
        SetStatus "Select a row in the table first." red
        return
    }
    set item [lindex $sel 0]
    lassign [$SF.res.tv item $item -values] rWin rSet oldNode oldSF
    set newNode [string trim [$SF.res.node get]]
    if {$newNode eq ""} {
        SetStatus "Enter a Node ID first." red
        return
    }
    SetStatus "Re-querying win $rWin node $newNode ..." blue
    if {[catch {::SafetyFactor::QueryNodeValue $rWin $newNode} result]} {
        SetStatus "Re-query FAILED: $result" red
        return
    }
    set sf3 [format "%.3f" $result]
    $SF.res.tv item $item -values [list $rWin $rSet $newNode $sf3]
    SFUpdateCsv $rWin $rSet $newNode $result
    SetStatus "Win $rWin / $rSet -> node $newNode = SF $sf3 (CSV updated)" darkgreen
}

proc ::HVTools::SFUpdateCsv {rWin rSet nodeID val} {
    set csvFile [file join $::SafetyFactor::LIB_DIR "SafetyFactor_Summary.csv"]
    if {![file exists $csvFile]} { return }
    set f [open $csvFile r]
    set lines {}
    while {[gets $f line] >= 0} { lappend lines $line }
    close $f
    set out {}
    foreach line $lines {
        set fields [split $line ","]
        if {[llength $fields] >= 4 && [lindex $fields 0] == $rWin && [lindex $fields 1] eq $rSet} {
            set lcLabel ""
            catch {set lcLabel [join [lrange $fields 4 end] ","]}
            lappend out "$rWin,$rSet,$nodeID,[format "%.5f" $val],$lcLabel"
        } else {
            lappend out $line
        }
    }
    set f [open $csvFile w]
    foreach line $out { puts $f $line }
    close $f
}

# ═════════════════════════ UI build ═════════════════════════

proc ::HVTools::BuildToolTab {tab kind} {
    # kind = ms | sf   (ms has the Angle column/field, sf doesn't)

    # ── Export ──
    labelframe $tab.exp -text " 1. Export (all windows) " -padx 8 -pady 6
    label  $tab.exp.lbl -text "Selection set IDs (space-separated):"
    entry  $tab.exp.ids -width 32
    button $tab.exp.run -text "Run Export" -width 14 \
        -command [expr {$kind eq "ms" ? "::HVTools::MSExport" : "::HVTools::SFExport"}]
    grid $tab.exp.lbl -row 0 -column 0 -sticky w
    grid $tab.exp.ids -row 1 -column 0 -sticky we -pady 2
    grid $tab.exp.run -row 1 -column 1 -padx {6 0}
    grid columnconfigure $tab.exp 0 -weight 1
    pack $tab.exp -fill x -padx 8 -pady {8 4}

    # ── Annotate ──
    labelframe $tab.ann -text " 2. Annotate (from CSV) " -padx 8 -pady 6
    label  $tab.ann.lbl -text "One selection set ID:"
    entry  $tab.ann.id -width 12
    button $tab.ann.run -text "Annotate" -width 14 \
        -command [expr {$kind eq "ms" ? "::HVTools::MSAnnotate" : "::HVTools::SFAnnotate"}]
    grid $tab.ann.lbl -row 0 -column 0 -sticky w
    grid $tab.ann.id  -row 1 -column 0 -sticky w -pady 2
    grid $tab.ann.run -row 1 -column 1 -padx {6 0}
    pack $tab.ann -fill x -padx 8 -pady 4

    # ── Options ──
    labelframe $tab.opt -text " Options " -padx 8 -pady 6
    if {$kind eq "ms"} {
        set ns ::MaxStress
    } else {
        set ns ::SafetyFactor
    }
    label $tab.opt.l1 -text "Marker size:"
    entry $tab.opt.mea -width 5 -textvariable ${ns}::MEA_FSIZE
    label $tab.opt.l2 -text "Note size:"
    entry $tab.opt.note -width 5 -textvariable ${ns}::NOTE_FSIZE
    label $tab.opt.l3 -text "Color (R G B):"
    entry $tab.opt.color -width 12 -textvariable ${ns}::PINK
    grid $tab.opt.l1    -row 0 -column 0 -sticky w
    grid $tab.opt.mea   -row 0 -column 1 -sticky w -padx {4 12}
    grid $tab.opt.l2    -row 0 -column 2 -sticky w
    grid $tab.opt.note  -row 0 -column 3 -sticky w -padx {4 0}
    grid $tab.opt.l3    -row 1 -column 0 -sticky w -pady {4 0}
    grid $tab.opt.color -row 1 -column 1 -columnspan 3 -sticky w -padx {4 0} -pady {4 0}
    checkbutton $tab.opt.shownote -text "Show note header" -variable ${ns}::SHOW_NOTE
    if {$kind eq "sf"} {
        label $tab.opt.l4 -text "Load case:"
        entry $tab.opt.lc -width 5 -textvariable ::SafetyFactor::SUBCASE
        label $tab.opt.l5 -text "Data type:"
        entry $tab.opt.dt -width 18 -textvariable ::SafetyFactor::DATATYPE
        grid $tab.opt.l4 -row 2 -column 0 -sticky w -pady {4 0}
        grid $tab.opt.lc -row 2 -column 1 -sticky w -padx {4 0} -pady {4 0}
        grid $tab.opt.l5 -row 3 -column 0 -sticky w -pady {4 0}
        grid $tab.opt.dt -row 3 -column 1 -columnspan 3 -sticky w -padx {4 0} -pady {4 0}
        grid $tab.opt.shownote -row 4 -column 0 -columnspan 3 -sticky w -pady {4 0}
    } else {
        grid $tab.opt.shownote -row 2 -column 0 -columnspan 3 -sticky w -pady {4 0}
    }
    pack $tab.opt -fill x -padx 8 -pady 4

    # ── Results table ──
    labelframe $tab.res -text " 3. Results — all windows " -padx 8 -pady 6
    if {$kind eq "ms"} {
        ttk::treeview $tab.res.tv -columns {win set node val angle} -show headings -height 8 \
            -yscrollcommand [list $tab.res.sb set]
        $tab.res.tv heading val   -text "Max Stress (MPa)"
        $tab.res.tv heading angle -text "Angle"
        $tab.res.tv column val   -width 110 -anchor e
        $tab.res.tv column angle -width 90  -anchor center
    } else {
        ttk::treeview $tab.res.tv -columns {win set node val} -show headings -height 8 \
            -yscrollcommand [list $tab.res.sb set]
        $tab.res.tv heading val -text "Min SF"
        $tab.res.tv column val -width 90 -anchor e
    }
    $tab.res.tv heading win  -text "Win"
    $tab.res.tv heading set  -text "Set"
    $tab.res.tv heading node -text "Node ID"
    $tab.res.tv column win  -width 40  -anchor center
    $tab.res.tv column set  -width 85  -anchor w
    $tab.res.tv column node -width 95  -anchor center
    scrollbar $tab.res.sb -orient vertical -command [list $tab.res.tv yview]

    frame  $tab.res.edit
    label  $tab.res.edit.l1 -text "Node ID:"
    entry  $tab.res.node -width 12
    if {$kind eq "ms"} {
        label $tab.res.edit.l2 -text "Angle:"
        entry $tab.res.ang -width 12
    }
    button $tab.res.requery -text "Re-query Value" \
        -command [expr {$kind eq "ms" ? "::HVTools::MSRequery" : "::HVTools::SFRequery"}]
    button $tab.res.refresh -text "Refresh from CSV" \
        -command [expr {$kind eq "ms" ? "::HVTools::MSLoadResults" : "::HVTools::SFLoadResults"}]

    grid $tab.res.tv   -row 0 -column 0 -sticky nswe
    grid $tab.res.sb   -row 0 -column 1 -sticky ns
    grid $tab.res.edit -row 1 -column 0 -sticky w -pady {4 0}
    pack $tab.res.edit.l1 -in $tab.res.edit -side left
    pack $tab.res.node    -in $tab.res.edit -side left -padx {4 10}
    if {$kind eq "ms"} {
        pack $tab.res.edit.l2 -in $tab.res.edit -side left
        pack $tab.res.ang     -in $tab.res.edit -side left -padx {4 10}
    }
    pack $tab.res.requery -in $tab.res.edit -side left
    grid $tab.res.refresh -row 2 -column 0 -sticky w -pady {4 0}
    grid columnconfigure $tab.res 0 -weight 1
    grid rowconfigure    $tab.res 0 -weight 1
    pack $tab.res -fill both -expand 1 -padx 8 -pady 4

    bind $tab.res.tv <<TreeviewSelect>> \
        [expr {$kind eq "ms" ? "::HVTools::MSOnSelect" : "::HVTools::SFOnSelect"}]
}

proc ::HVTools::Build {} {
    variable W
    variable MS
    variable SF
    variable HAS_SF

    catch {destroy $W}
    toplevel $W
    wm title $W "HV Tools — Max Stress / Safety Factor — Nguyen Tan Loc"
    wm attributes $W -topmost 1
    wm resizable $W 0 1

    # ── Shared Load section ──
    labelframe $W.load -text " 0. Load model & results " -padx 8 -pady 6
    label  $W.load.lm -text "Model file (shared by all windows):"
    entry  $W.load.model -width 46
    button $W.load.bm -text "..." -width 3 -command ::HVTools::BrowseModel
    label  $W.load.lr -text "Result files (one per line — one window each):"
    text   $W.load.res -width 46 -height 4 -yscrollcommand [list $W.load.rsb set]
    scrollbar $W.load.rsb -orient vertical -command [list $W.load.res yview]
    button $W.load.br -text "Add..." -width 6 -command ::HVTools::BrowseResults
    frame  $W.load.lay
    label  $W.load.lay.l -text "Layout:"
    entry  $W.load.cols -width 3
    label  $W.load.lay.x -text "x"
    entry  $W.load.rows -width 3
    label  $W.load.lay.hint -text "(ngang x doc)"
    button $W.load.run -text "Load All" -width 14 -command ::HVTools::DoLoadAll

    grid $W.load.lm    -row 0 -column 0 -columnspan 2 -sticky w
    grid $W.load.model -row 1 -column 0 -sticky we -pady 2
    grid $W.load.bm    -row 1 -column 1 -padx {4 0}
    grid $W.load.lr    -row 2 -column 0 -columnspan 2 -sticky w -pady {6 0}
    grid $W.load.res   -row 3 -column 0 -sticky we -pady 2
    grid $W.load.rsb   -row 3 -column 1 -sticky ns
    grid $W.load.br    -row 4 -column 0 -sticky w
    grid $W.load.lay   -row 5 -column 0 -sticky w -pady {6 0}
    pack $W.load.lay.l    -in $W.load.lay -side left
    pack $W.load.cols     -in $W.load.lay -side left -padx {4 2}
    pack $W.load.lay.x    -in $W.load.lay -side left
    pack $W.load.rows     -in $W.load.lay -side left -padx {2 4}
    pack $W.load.lay.hint -in $W.load.lay -side left
    pack $W.load.run      -in $W.load.lay -side left -padx {20 0}
    grid columnconfigure $W.load 0 -weight 1
    pack $W.load -fill x -padx 10 -pady {10 4}

    $W.load.cols insert 0 "4"
    $W.load.rows insert 0 "2"

    # ── Notebook: one tab per tool ──
    ttk::notebook $W.nb
    frame $W.nb.ms
    frame $W.nb.sf
    $W.nb add $W.nb.ms -text "  Max Stress  "
    $W.nb add $W.nb.sf -text "  Safety Factor  "
    set MS $W.nb.ms
    set SF $W.nb.sf

    BuildToolTab $MS ms
    if {$HAS_SF} {
        BuildToolTab $SF sf
    } else {
        label $SF.missing -text "safetyfactor_lib.tcl not found in this folder.\nCopy it from the Tcl_Safety-Factor- repo next to this panel file." \
            -foreground red -justify left
        pack $SF.missing -padx 20 -pady 30 -anchor w
    }
    pack $W.nb -fill both -expand 1 -padx 10 -pady 4

    # ── Status bar ──
    label $W.status -text "Ready." -anchor w -relief sunken -padx 6
    pack $W.status -fill x -side bottom -padx 10 -pady {4 10}

    # Pre-fill tables from existing CSVs
    catch {MSLoadResults}
    if {$HAS_SF} { catch {SFLoadResults} }

    # ── Auto-load on open (saved config from the last "Load All") ──
    set cfg [LoadConfig]
    if {$cfg ne ""} {
        lassign $cfg modelFile cols rows resultFiles
        $W.load.model delete 0 end ; $W.load.model insert 0 $modelFile
        $W.load.cols  delete 0 end ; $W.load.cols  insert 0 $cols
        $W.load.rows  delete 0 end ; $W.load.rows  insert 0 $rows
        $W.load.res   delete 1.0 end
        foreach rf $resultFiles { $W.load.res insert end "$rf\n" }

        set missing 0
        if {![file exists $modelFile]} { set missing 1 }
        foreach rf $resultFiles { if {![file exists $rf]} { set missing 1 } }
        if {$missing} {
            SetStatus "Saved paths restored — some files missing, auto-load skipped." red
        } else {
            SetStatus "Auto-loading saved model & results..." blue
            after idle ::HVTools::DoLoadAll
        }
    }
}

::HVTools::Build
puts "HV Tools panel loaded — window '[wm title $::HVTools::W]' is open."
