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
    # Current selection in the per-window results grids
    variable MS_CURTV   ""
    variable MS_CURITEM ""
    variable MS_CURWIN  ""
    variable MS_CURSET  ""
    variable SF_CURTV   ""
    variable SF_CURITEM ""
    variable SF_CURWIN  ""
    variable SF_CURSET  ""
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

# Populate the data-type droplist from window 1's model
proc ::HVTools::MSFetchTypes {} {
    variable MS
    SetStatus "Fetching data-type list from window 1..." blue
    if {[catch {::MaxStress::FetchTypeList} dts] || $dts eq ""} {
        SetStatus "Fetch failed — is a model loaded in window 1?" red
        return
    }
    $MS.opt.dt configure -values $dts
    MSFetchComps
    SetStatus "Loaded [llength $dts] data types (component list refreshed)." darkgreen
}

# Populate the component droplist for the currently selected data type
proc ::HVTools::MSFetchComps {} {
    variable MS
    set dt $::MaxStress::DATATYPE
    if {[catch {::MaxStress::FetchComponentList $dt} comps] || $comps eq ""} {
        $MS.opt.comp configure -values {}
        SetStatus "No component list for '$dt' (type one manually)." red
        return
    }
    $MS.opt.comp configure -values $comps
    # Keep the current component if still valid, else pick the first
    if {[lsearch -exact $comps $::MaxStress::DATACOMP] < 0} {
        set ::MaxStress::DATACOMP [lindex $comps 0]
    }
}

# Layout cols x rows from the Load section (fallback 4x2)
proc ::HVTools::GetLayoutCR {} {
    variable W
    set c 4 ; set r 2
    catch {
        set cc [string trim [$W.load.cols get]]
        set rr [string trim [$W.load.rows get]]
        if {[string is integer -strict $cc] && $cc > 0} { set c $cc }
        if {[string is integer -strict $rr] && $rr > 0} { set r $rr }
    }
    return [list $c $r]
}

# Rebuild the per-window results grid (one block per window, arranged to
# mirror the page layout) and fill it from Stress_Summary.csv.
proc ::HVTools::MSLoadResults {} {
    variable MS
    variable MS_CURTV ; variable MS_CURITEM ; variable MS_CURWIN ; variable MS_CURSET
    set csvFile [file join $::MaxStress::LIB_DIR "Stress_Summary.csv"]

    foreach ch [winfo children $MS.res.grid] { destroy $ch }
    set MS_CURTV "" ; set MS_CURITEM "" ; set MS_CURWIN "" ; set MS_CURSET ""

    if {![file exists $csvFile]} {
        SetStatus "No stress CSV yet — run Export first." red
        return
    }

    # Read + group rows by window
    array set winRows {}
    set f [open $csvFile r]
    set lineNo 0 ; set n 0
    while {[gets $f line] >= 0} {
        incr lineNo
        if {$lineNo == 1 || [string trim $line] eq ""} { continue }
        set fields [split $line ","]
        if {[llength $fields] < 6} { continue }
        lassign $fields rWin rSetName rNodeID rStress rSimID rAngle
        set stress3 [::MaxStress::Fmt $rStress]
        lappend winRows($rWin) [list $rSetName $rNodeID $stress3 $rAngle]
        incr n
    }
    close $f

    lassign [GetLayoutCR] cols rows
    set total [expr {$cols * $rows}]

    # Mini-table height = most rows any window has (clamped 2..8)
    set maxRows 2
    foreach w [array names winRows] {
        if {[llength $winRows($w)] > $maxRows} { set maxRows [llength $winRows($w)] }
    }
    if {$maxRows > 8} { set maxRows 8 }

    for {set wi 1} {$wi <= $total} {incr wi} {
        set rr [expr {($wi - 1) / $cols}]
        set cc [expr {($wi - 1) % $cols}]
        set blk $MS.res.grid.w$wi
        labelframe $blk -text " Win $wi " -padx 2 -pady 2
        ttk::treeview $blk.tv -columns {set node val angle} -show headings -height $maxRows
        $blk.tv heading set   -text "Set"
        $blk.tv heading node  -text "Node ID"
        $blk.tv heading val   -text "Value"
        $blk.tv heading angle -text "Angle"
        $blk.tv column set   -width 48  -anchor w
        $blk.tv column node  -width 72  -anchor center
        $blk.tv column val   -width 58  -anchor e
        $blk.tv column angle -width 66  -anchor center
        pack $blk.tv -fill both -expand 1
        grid $blk -row $rr -column $cc -sticky nswe -padx 2 -pady 2
        grid columnconfigure $MS.res.grid $cc -weight 1
        grid rowconfigure    $MS.res.grid $rr -weight 1

        if {[info exists winRows($wi)]} {
            foreach row $winRows($wi) {
                $blk.tv insert {} end -values $row
            }
        }
        bind $blk.tv <<TreeviewSelect>> [list ::HVTools::MSOnSelectBlock $wi $blk.tv]
    }
    SetStatus "Stress results: $n row(s) in ${cols}x${rows} grid." darkgreen
}

# Row clicked in a window block -> remember it + fill the edit fields
proc ::HVTools::MSOnSelectBlock {win tv} {
    variable MS
    variable MS_CURTV ; variable MS_CURITEM ; variable MS_CURWIN ; variable MS_CURSET
    set sel [$tv selection]
    if {[llength $sel] == 0} { return }
    set item [lindex $sel 0]
    lassign [$tv item $item -values] rSet rNode rVal rAngle
    set MS_CURTV $tv ; set MS_CURITEM $item ; set MS_CURWIN $win ; set MS_CURSET $rSet
    $MS.res.node delete 0 end ; $MS.res.node insert 0 $rNode
    $MS.res.ang  delete 0 end ; $MS.res.ang  insert 0 $rAngle
    # Deselect rows in the other window blocks so the active row is unambiguous
    foreach blk [winfo children $MS.res.grid] {
        set otv $blk.tv
        if {[winfo exists $otv] && $otv ne $tv} {
            catch {$otv selection remove [$otv selection]}
        }
    }
    SetStatus "Selected: Win $win / $rSet (node $rNode @ $rAngle)"
}

proc ::HVTools::MSRequery {} {
    variable MS
    variable MS_CURTV ; variable MS_CURITEM ; variable MS_CURWIN ; variable MS_CURSET
    if {$MS_CURTV eq "" || ![winfo exists $MS_CURTV]} {
        SetStatus "Select a row in a window block first." red
        return
    }
    set newNode  [string trim [$MS.res.node get]]
    set newAngle [string trim [$MS.res.ang get]]
    if {$newNode eq "" || $newAngle eq ""} {
        SetStatus "Enter Node ID and Angle first." red
        return
    }
    SetStatus "Re-querying win $MS_CURWIN node $newNode @ $newAngle ..." blue
    if {[catch {::MaxStress::QueryNodeValue $MS_CURWIN $newNode $newAngle} result]} {
        SetStatus "Re-query FAILED: $result" red
        return
    }
    lassign $result val simIdx simLabel angleStr
    set stress3 [::MaxStress::Fmt $val]
    $MS_CURTV item $MS_CURITEM -values [list $MS_CURSET $newNode $stress3 $angleStr]
    MSUpdateCsv $MS_CURWIN $MS_CURSET $newNode $val $simIdx $angleStr $simLabel
    SetStatus "Win $MS_CURWIN / $MS_CURSET -> node $newNode @ $angleStr = $stress3 MPa (CSV updated)" darkgreen
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

# Populate the SF data-type droplist from window 1's model
proc ::HVTools::SFFetchTypes {} {
    variable SF
    SetStatus "Fetching data-type list from window 1..." blue
    if {[catch {::SafetyFactor::FetchTypeList} dts] || $dts eq ""} {
        SetStatus "Fetch failed — is a model loaded in window 1?" red
        return
    }
    $SF.opt.dt configure -values $dts
    SFFetchComps
    SetStatus "Loaded [llength $dts] data types (component list refreshed)." darkgreen
}

proc ::HVTools::SFFetchComps {} {
    variable SF
    set dt $::SafetyFactor::DATATYPE
    if {[catch {::SafetyFactor::FetchComponentList $dt} comps] || $comps eq ""} {
        $SF.opt.comp configure -values {}
        SetStatus "No component list for '$dt' (type one manually)." red
        return
    }
    $SF.opt.comp configure -values $comps
    if {[lsearch -exact $comps $::SafetyFactor::DATACOMP] < 0} {
        set ::SafetyFactor::DATACOMP [lindex $comps 0]
    }
}

# Rebuild the SF per-window results grid from SafetyFactor_Summary.csv
proc ::HVTools::SFLoadResults {} {
    variable SF
    variable SF_CURTV ; variable SF_CURITEM ; variable SF_CURWIN ; variable SF_CURSET
    set csvFile [file join $::SafetyFactor::LIB_DIR "SafetyFactor_Summary.csv"]

    foreach ch [winfo children $SF.res.grid] { destroy $ch }
    set SF_CURTV "" ; set SF_CURITEM "" ; set SF_CURWIN "" ; set SF_CURSET ""

    if {![file exists $csvFile]} {
        SetStatus "No SF CSV yet — run Export first." red
        return
    }

    array set winRows {}
    set f [open $csvFile r]
    set lineNo 0 ; set n 0
    while {[gets $f line] >= 0} {
        incr lineNo
        if {$lineNo == 1 || [string trim $line] eq ""} { continue }
        set fields [split $line ","]
        if {[llength $fields] < 4} { continue }
        lassign $fields rWin rSetName rNodeID rSF
        lappend winRows($rWin) [list $rSetName $rNodeID [::SafetyFactor::Fmt $rSF]]
        incr n
    }
    close $f

    lassign [GetLayoutCR] cols rows
    set total [expr {$cols * $rows}]

    set maxRows 2
    foreach w [array names winRows] {
        if {[llength $winRows($w)] > $maxRows} { set maxRows [llength $winRows($w)] }
    }
    if {$maxRows > 8} { set maxRows 8 }

    for {set wi 1} {$wi <= $total} {incr wi} {
        set rr [expr {($wi - 1) / $cols}]
        set cc [expr {($wi - 1) % $cols}]
        set blk $SF.res.grid.w$wi
        labelframe $blk -text " Win $wi " -padx 2 -pady 2
        ttk::treeview $blk.tv -columns {set node val} -show headings -height $maxRows
        $blk.tv heading set  -text "Set"
        $blk.tv heading node -text "Node ID"
        $blk.tv heading val  -text "Min SF"
        $blk.tv column set  -width 56 -anchor w
        $blk.tv column node -width 78 -anchor center
        $blk.tv column val  -width 62 -anchor e
        pack $blk.tv -fill both -expand 1
        grid $blk -row $rr -column $cc -sticky nswe -padx 2 -pady 2
        grid columnconfigure $SF.res.grid $cc -weight 1
        grid rowconfigure    $SF.res.grid $rr -weight 1

        if {[info exists winRows($wi)]} {
            foreach row $winRows($wi) {
                $blk.tv insert {} end -values $row
            }
        }
        bind $blk.tv <<TreeviewSelect>> [list ::HVTools::SFOnSelectBlock $wi $blk.tv]
    }
    SetStatus "SF results: $n row(s) in ${cols}x${rows} grid." darkgreen
}

# Row clicked in a window block -> remember it + fill the edit field
proc ::HVTools::SFOnSelectBlock {win tv} {
    variable SF
    variable SF_CURTV ; variable SF_CURITEM ; variable SF_CURWIN ; variable SF_CURSET
    set sel [$tv selection]
    if {[llength $sel] == 0} { return }
    set item [lindex $sel 0]
    lassign [$tv item $item -values] rSet rNode rVal
    set SF_CURTV $tv ; set SF_CURITEM $item ; set SF_CURWIN $win ; set SF_CURSET $rSet
    $SF.res.node delete 0 end ; $SF.res.node insert 0 $rNode
    foreach blk [winfo children $SF.res.grid] {
        set otv $blk.tv
        if {[winfo exists $otv] && $otv ne $tv} {
            catch {$otv selection remove [$otv selection]}
        }
    }
    SetStatus "Selected: Win $win / $rSet (node $rNode)"
}

proc ::HVTools::SFRequery {} {
    variable SF
    variable SF_CURTV ; variable SF_CURITEM ; variable SF_CURWIN ; variable SF_CURSET
    if {$SF_CURTV eq "" || ![winfo exists $SF_CURTV]} {
        SetStatus "Select a row in a window block first." red
        return
    }
    set newNode [string trim [$SF.res.node get]]
    if {$newNode eq ""} {
        SetStatus "Enter a Node ID first." red
        return
    }
    SetStatus "Re-querying win $SF_CURWIN node $newNode ..." blue
    if {[catch {::SafetyFactor::QueryNodeValue $SF_CURWIN $newNode} result]} {
        SetStatus "Re-query FAILED: $result" red
        return
    }
    set sf3 [::SafetyFactor::Fmt $result]
    $SF_CURTV item $SF_CURITEM -values [list $SF_CURSET $newNode $sf3]
    SFUpdateCsv $SF_CURWIN $SF_CURSET $newNode $result
    SetStatus "Win $SF_CURWIN / $SF_CURSET -> node $newNode = SF $sf3 (CSV updated)" darkgreen
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
        label $tab.opt.l6 -text "Precision:"
        entry $tab.opt.prec -width 4 -textvariable ::SafetyFactor::PRECISION
        label $tab.opt.l5 -text "Data type:"
        ttk::combobox $tab.opt.dt -width 26 -textvariable ::SafetyFactor::DATATYPE
        button $tab.opt.fetch -text "Fetch lists" -width 10 -command ::HVTools::SFFetchTypes
        label $tab.opt.l8 -text "Component:"
        ttk::combobox $tab.opt.comp -width 18 -textvariable ::SafetyFactor::DATACOMP
        grid $tab.opt.l6    -row 2 -column 0 -sticky w -pady {4 0}
        grid $tab.opt.prec  -row 2 -column 1 -sticky w -padx {4 0} -pady {4 0}
        grid $tab.opt.l5    -row 3 -column 0 -sticky w -pady {4 0}
        grid $tab.opt.dt    -row 3 -column 1 -columnspan 2 -sticky w -padx {4 0} -pady {4 0}
        grid $tab.opt.fetch -row 3 -column 3 -sticky w -padx {6 0} -pady {4 0}
        grid $tab.opt.l8    -row 4 -column 0 -sticky w -pady {4 0}
        grid $tab.opt.comp  -row 4 -column 1 -columnspan 2 -sticky w -padx {4 0} -pady {4 0}
        grid $tab.opt.shownote -row 5 -column 0 -columnspan 3 -sticky w -pady {4 0}
        bind $tab.opt.dt <<ComboboxSelected>> ::HVTools::SFFetchComps
    } else {
        grid $tab.opt.shownote -row 2 -column 0 -columnspan 3 -sticky w -pady {4 0}
        # Precision + data type / component droplists (Max Stress only)
        label $tab.opt.l6 -text "Precision:"
        entry $tab.opt.prec -width 4 -textvariable ::MaxStress::PRECISION
        grid $tab.opt.l6   -row 3 -column 0 -sticky w -pady {4 0}
        grid $tab.opt.prec -row 3 -column 1 -sticky w -padx {4 0} -pady {4 0}
        label $tab.opt.l7 -text "Data type:"
        ttk::combobox $tab.opt.dt -width 26 -textvariable ::MaxStress::DATATYPE
        button $tab.opt.fetch -text "Fetch lists" -width 10 -command ::HVTools::MSFetchTypes
        grid $tab.opt.l7    -row 4 -column 0 -sticky w -pady {4 0}
        grid $tab.opt.dt    -row 4 -column 1 -columnspan 2 -sticky w -padx {4 0} -pady {4 0}
        grid $tab.opt.fetch -row 4 -column 3 -sticky w -padx {6 0} -pady {4 0}
        label $tab.opt.l8 -text "Component:"
        ttk::combobox $tab.opt.comp -width 18 -textvariable ::MaxStress::DATACOMP
        grid $tab.opt.l8   -row 5 -column 0 -sticky w -pady {4 0}
        grid $tab.opt.comp -row 5 -column 1 -columnspan 2 -sticky w -padx {4 0} -pady {4 0}
        bind $tab.opt.dt <<ComboboxSelected>> ::HVTools::MSFetchComps
    }
    pack $tab.opt -fill x -padx 8 -pady 4

    # ── Results ──
    labelframe $tab.res -text " 3. Results — all windows " -padx 8 -pady 6
    if {$kind eq "ms"} {
        # Per-window grid mirroring the page layout; blocks are (re)built by
        # MSLoadResults from the CSV + the Load section's cols x rows.
        frame $tab.res.grid
        frame  $tab.res.edit
        label  $tab.res.edit.l1 -text "Node ID:"
        entry  $tab.res.node -width 12
        label  $tab.res.edit.l2 -text "Angle:"
        entry  $tab.res.ang -width 12
        button $tab.res.requery -text "Re-query Value" -command ::HVTools::MSRequery
        button $tab.res.refresh -text "Refresh from CSV" -command ::HVTools::MSLoadResults

        grid $tab.res.grid -row 0 -column 0 -sticky nswe
        grid $tab.res.edit -row 1 -column 0 -sticky w -pady {4 0}
        pack $tab.res.edit.l1 -in $tab.res.edit -side left
        pack $tab.res.node    -in $tab.res.edit -side left -padx {4 10}
        pack $tab.res.edit.l2 -in $tab.res.edit -side left
        pack $tab.res.ang     -in $tab.res.edit -side left -padx {4 10}
        pack $tab.res.requery -in $tab.res.edit -side left
        grid $tab.res.refresh -row 2 -column 0 -sticky w -pady {4 0}
        grid columnconfigure $tab.res 0 -weight 1
        grid rowconfigure    $tab.res 0 -weight 1
        pack $tab.res -fill both -expand 1 -padx 8 -pady 4
    } else {
        # SF: same per-window grid as the Max Stress tab (no Angle column)
        frame $tab.res.grid
        frame  $tab.res.edit
        label  $tab.res.edit.l1 -text "Node ID:"
        entry  $tab.res.node -width 12
        button $tab.res.requery -text "Re-query Value" -command ::HVTools::SFRequery
        button $tab.res.refresh -text "Refresh from CSV" -command ::HVTools::SFLoadResults

        grid $tab.res.grid -row 0 -column 0 -sticky nswe
        grid $tab.res.edit -row 1 -column 0 -sticky w -pady {4 0}
        pack $tab.res.edit.l1 -in $tab.res.edit -side left
        pack $tab.res.node    -in $tab.res.edit -side left -padx {4 10}
        pack $tab.res.requery -in $tab.res.edit -side left
        grid $tab.res.refresh -row 2 -column 0 -sticky w -pady {4 0}
        grid columnconfigure $tab.res 0 -weight 1
        grid rowconfigure    $tab.res 0 -weight 1
        pack $tab.res -fill both -expand 1 -padx 8 -pady 4
    }
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
    wm resizable $W 1 1     ;# fully resizable — the per-window results grid needs width

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
