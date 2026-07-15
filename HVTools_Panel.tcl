# HVTools_Panel.tcl — combined add-in panel: Max Stress + Safety Factor.
#
# Layout: LEFT column (narrow) = shared "0. Load model & results" section +
# a tabbed notebook (Max Stress / Safety Factor, each with Export/Annotate/
# Options only). RIGHT column (wide) = "3. Results — all windows" — title +
# controls at the top, per-window grid below — showing whichever tab's
# results are currently active (switches automatically with the notebook).
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
    variable MS ""      ;# notebook tab frame (Export/Annotate/Options)
    variable SF ""
    variable MSRES ""   ;# results-pane frame (right column)
    variable SFRES ""
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
    # Element-display dropdown selections
    variable MS_ELEM "Shaded + Feature Lines"
    variable SF_ELEM "Shaded + Feature Lines"
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
        $W.left.load.model delete 0 end
        $W.left.load.model insert 0 $f
    }
}

proc ::HVTools::BrowseResults {} {
    variable W
    set files [tk_getOpenFile -title "Select result file(s)" -multiple 1 \
        -filetypes {{"Result files" {.odb .res .op2 .h3d}} {"All files" *}}]
    foreach f $files {
        $W.left.load.res insert end "$f\n"
    }
}

proc ::HVTools::ReadLoadFields {} {
    variable W
    set modelFile [string trim [$W.left.load.model get]]
    set cols [string trim [$W.left.load.cols get]]
    set rows [string trim [$W.left.load.rows get]]
    set resultFiles {}
    foreach line [split [$W.left.load.res get 1.0 end] "\n"] {
        set line [string trim $line]
        if {$line ne ""} { lappend resultFiles $line }
    }
    return [list $modelFile $cols $rows $resultFiles]
}

proc ::HVTools::DoReset {} {
    SetStatus "Resetting session (File > New)..." blue
    if {[catch {::MaxStress::ResetSession} err]} {
        SetStatus "Reset FAILED: $err" red
    } else {
        SetStatus "Session reset — all windows cleared. Now click Load All." darkgreen
    }
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
    $MS.opt.recheck.dt configure -values $dts
    MSFetchComps
    SetStatus "Loaded [llength $dts] data types (component list refreshed)." darkgreen
}

# Populate the component droplist for the currently selected data type
proc ::HVTools::MSFetchComps {} {
    variable MS
    set dt $::MaxStress::DATATYPE
    if {[catch {::MaxStress::FetchComponentList $dt} comps] || $comps eq ""} {
        $MS.opt.recheck.comp configure -values {}
        SetStatus "No component list for '$dt' (type one manually)." red
        return
    }
    $MS.opt.recheck.comp configure -values $comps
    # Keep the current component if still valid, else pick the first
    if {[lsearch -exact $comps $::MaxStress::DATACOMP] < 0} {
        set ::MaxStress::DATACOMP [lindex $comps 0]
    }
}

# Browse for the optional annotate-legend TCL (ns = ::MaxStress | ::SafetyFactor)
proc ::HVTools::BrowseLegend {ns} {
    set f [tk_getOpenFile -title "Select legend TCL (annotate/capture only)" \
        -filetypes {{"TCL files" {.tcl}} {"All files" *}}]
    if {$f ne ""} {
        set ${ns}::LEGEND_TCL $f
    }
}

# Browse for the optional view-list .txt (ns = ::MaxStress | ::SafetyFactor)
proc ::HVTools::BrowseViewFile {ns} {
    set f [tk_getOpenFile -title "Select view list .txt (*ViewName/*Matrix export)" \
        -filetypes {{"Text files" {.txt}} {"All files" *}}]
    if {$f ne ""} {
        set ${ns}::VIEW_TXT $f
    }
}

proc ::HVTools::MSImportViews {} {
    set path $::MaxStress::VIEW_TXT
    if {[string trim $path] eq ""} {
        SetStatus "Pick a view list .txt first." red
        return
    }
    SetStatus "Importing views into all windows..." blue
    if {[catch {::MaxStress::RunImportViews $path} result]} {
        SetStatus "Import views FAILED: $result" red
    } else {
        lassign $result numWindows numViews
        SetStatus "Imported $numViews view(s) into $numWindows window(s)." darkgreen
    }
}

proc ::HVTools::SFImportViews {} {
    set path $::SafetyFactor::VIEW_TXT
    if {[string trim $path] eq ""} {
        SetStatus "Pick a view list .txt first." red
        return
    }
    SetStatus "Importing views into all windows..." blue
    if {[catch {::SafetyFactor::RunImportViews $path} result]} {
        SetStatus "Import views FAILED: $result" red
    } else {
        lassign $result numWindows numViews
        SetStatus "Imported $numViews view(s) into $numWindows window(s)." darkgreen
    }
}

proc ::HVTools::MSCapture {} {
    variable MS
    set setID [string trim [$MS.ann.id get]]
    if {$setID eq ""} {
        SetStatus "Enter one selection set ID first (same field as Annotate)." red
        return
    }
    SetStatus "Capturing images for all windows..." blue
    if {[catch {::MaxStress::RunCapture $setID} result]} {
        SetStatus "Capture FAILED: $result" red
    } else {
        SetStatus "Captured images for $result window(s) -> $::MaxStress::LIB_DIR" darkgreen
    }
}

proc ::HVTools::SFCapture {} {
    variable SF
    set setID [string trim [$SF.ann.id get]]
    if {$setID eq ""} {
        SetStatus "Enter one selection set ID first (same field as Annotate)." red
        return
    }
    SetStatus "Capturing images for all windows..." blue
    if {[catch {::SafetyFactor::RunCapture $setID} result]} {
        SetStatus "Capture FAILED: $result" red
    } else {
        SetStatus "Captured images for $result window(s) -> $::SafetyFactor::LIB_DIR" darkgreen
    }
}

# Element-display dropdown label -> component SetMeshMode value
proc ::HVTools::ElemMode {label} {
    switch -glob -- $label {
        "*Mesh*"    { return meshlines }
        "*Feature*" { return features }
        default     { return none }
    }
}

proc ::HVTools::MSApplyDisplay {} {
    variable MS_ELEM
    SetStatus "Applying display to all windows..." blue
    if {[catch {::MaxStress::ApplyDisplay $::MaxStress::SHOW_LEGEND [ElemMode $MS_ELEM]} err]} {
        SetStatus "Apply display FAILED: $err" red
    } else {
        SetStatus "Display applied (legend=$::MaxStress::SHOW_LEGEND, $MS_ELEM)." darkgreen
    }
}

proc ::HVTools::SFApplyDisplay {} {
    variable SF_ELEM
    SetStatus "Applying display to all windows..." blue
    if {[catch {::SafetyFactor::ApplyDisplay $::SafetyFactor::SHOW_LEGEND [ElemMode $SF_ELEM]} err]} {
        SetStatus "Apply display FAILED: $err" red
    } else {
        SetStatus "Display applied (legend=$::SafetyFactor::SHOW_LEGEND, $SF_ELEM)." darkgreen
    }
}

# Layout cols x rows from the Load section (fallback 4x2)
proc ::HVTools::GetLayoutCR {} {
    variable W
    set c 4 ; set r 2
    catch {
        set cc [string trim [$W.left.load.cols get]]
        set rr [string trim [$W.left.load.rows get]]
        if {[string is integer -strict $cc] && $cc > 0} { set c $cc }
        if {[string is integer -strict $rr] && $rr > 0} { set r $rr }
    }
    return [list $c $r]
}

# Rebuild the per-window results grid (one block per window, arranged to
# mirror the page layout) and fill it from Stress_Summary.csv.
proc ::HVTools::MSLoadResults {} {
    variable MSRES
    variable MS_CURTV ; variable MS_CURITEM ; variable MS_CURWIN ; variable MS_CURSET
    set csvFile [file join $::MaxStress::LIB_DIR "Stress_Summary.csv"]

    foreach ch [winfo children $MSRES.grid] { destroy $ch }
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

    # Mini-table height = most rows any window has (clamped 2..9 — priority
    # is showing up to 9 sets at a glance; a per-block scrollbar handles
    # windows with more than that).
    set maxRows 2
    foreach w [array names winRows] {
        if {[llength $winRows($w)] > $maxRows} { set maxRows [llength $winRows($w)] }
    }
    if {$maxRows > 9} { set maxRows 9 }

    for {set wi 1} {$wi <= $total} {incr wi} {
        set rr [expr {($wi - 1) / $cols}]
        set cc [expr {($wi - 1) % $cols}]
        set blk $MSRES.grid.w$wi
        labelframe $blk -text " Win $wi " -padx 2 -pady 2
        ttk::treeview $blk.tv -columns {set node val angle} -show headings -height $maxRows \
            -yscrollcommand [list $blk.sb set]
        scrollbar $blk.sb -orient vertical -command [list $blk.tv yview]
        $blk.tv heading set   -text "Set"
        $blk.tv heading node  -text "Node ID"
        $blk.tv heading val   -text "Value"
        $blk.tv heading angle -text "Angle"
        $blk.tv column set   -width 48  -anchor w
        $blk.tv column node  -width 72  -anchor center
        $blk.tv column val   -width 58  -anchor e
        $blk.tv column angle -width 66  -anchor center
        pack $blk.sb -side right -fill y
        pack $blk.tv -side left -fill both -expand 1
        grid $blk -row $rr -column $cc -sticky nswe -padx 2 -pady 2
        grid columnconfigure $MSRES.grid $cc -weight 1
        grid rowconfigure    $MSRES.grid $rr -weight 1

        if {[info exists winRows($wi)]} {
            foreach row $winRows($wi) {
                $blk.tv insert {} end -values $row
            }
        }
        bind $blk.tv <<TreeviewSelect>> [list ::HVTools::MSOnSelectBlock $wi $blk.tv]
    }
    SetStatus "Stress results: $n row(s) in ${cols}x${rows} grid." darkgreen
}

# Re-layout Stress_Summary.csv into the pivoted Stress_Report.csv
# (pure file operation — no HyperView involved, instant)
proc ::HVTools::MSMakeReport {} {
    lassign [GetLayoutCR] gcols grows
    SetStatus "Building report from CSV..." blue
    if {[catch {::MaxStress::MakeReport "" $gcols} result]} {
        SetStatus "Report FAILED: $result" red
    } else {
        SetStatus "Report -> $result" darkgreen
    }
}

# Row clicked in a window block -> remember it + fill the edit fields
proc ::HVTools::MSOnSelectBlock {win tv} {
    variable MSRES
    variable MS_CURTV ; variable MS_CURITEM ; variable MS_CURWIN ; variable MS_CURSET
    set sel [$tv selection]
    if {[llength $sel] == 0} { return }
    set item [lindex $sel 0]
    lassign [$tv item $item -values] rSet rNode rVal rAngle
    set MS_CURTV $tv ; set MS_CURITEM $item ; set MS_CURWIN $win ; set MS_CURSET $rSet
    $MSRES.node delete 0 end ; $MSRES.node insert 0 $rNode
    $MSRES.ang  delete 0 end ; $MSRES.ang  insert 0 $rAngle
    # Deselect rows in the other window blocks so the active row is unambiguous
    foreach blk [winfo children $MSRES.grid] {
        set otv $blk.tv
        if {[winfo exists $otv] && $otv ne $tv} {
            catch {$otv selection remove [$otv selection]}
        }
    }
    SetStatus "Selected: Win $win / $rSet (node $rNode @ $rAngle)"
}

proc ::HVTools::MSRequery {} {
    variable MSRES
    variable MS_CURTV ; variable MS_CURITEM ; variable MS_CURWIN ; variable MS_CURSET
    if {$MS_CURTV eq "" || ![winfo exists $MS_CURTV]} {
        SetStatus "Select a row in a window block first." red
        return
    }
    set newNode  [string trim [$MSRES.node get]]
    set newAngle [string trim [$MSRES.ang get]]
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
    $SF.opt.recheck.dt configure -values $dts
    SFFetchComps
    SetStatus "Loaded [llength $dts] data types (component list refreshed)." darkgreen
}

proc ::HVTools::SFFetchComps {} {
    variable SF
    set dt $::SafetyFactor::DATATYPE
    if {[catch {::SafetyFactor::FetchComponentList $dt} comps] || $comps eq ""} {
        $SF.opt.recheck.comp configure -values {}
        SetStatus "No component list for '$dt' (type one manually)." red
        return
    }
    $SF.opt.recheck.comp configure -values $comps
    if {[lsearch -exact $comps $::SafetyFactor::DATACOMP] < 0} {
        set ::SafetyFactor::DATACOMP [lindex $comps 0]
    }
}

# Rebuild the SF per-window results grid from SafetyFactor_Summary.csv
proc ::HVTools::SFLoadResults {} {
    variable SFRES
    variable SF_CURTV ; variable SF_CURITEM ; variable SF_CURWIN ; variable SF_CURSET
    set csvFile [file join $::SafetyFactor::LIB_DIR "SafetyFactor_Summary.csv"]

    foreach ch [winfo children $SFRES.grid] { destroy $ch }
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
    if {$maxRows > 9} { set maxRows 9 }

    for {set wi 1} {$wi <= $total} {incr wi} {
        set rr [expr {($wi - 1) / $cols}]
        set cc [expr {($wi - 1) % $cols}]
        set blk $SFRES.grid.w$wi
        labelframe $blk -text " Win $wi " -padx 2 -pady 2
        ttk::treeview $blk.tv -columns {set node val} -show headings -height $maxRows \
            -yscrollcommand [list $blk.sb set]
        scrollbar $blk.sb -orient vertical -command [list $blk.tv yview]
        $blk.tv heading set  -text "Set"
        $blk.tv heading node -text "Node ID"
        $blk.tv heading val  -text "Min SF"
        $blk.tv column set  -width 56 -anchor w
        $blk.tv column node -width 78 -anchor center
        $blk.tv column val  -width 62 -anchor e
        pack $blk.sb -side right -fill y
        pack $blk.tv -side left -fill both -expand 1
        grid $blk -row $rr -column $cc -sticky nswe -padx 2 -pady 2
        grid columnconfigure $SFRES.grid $cc -weight 1
        grid rowconfigure    $SFRES.grid $rr -weight 1

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
    variable SFRES
    variable SF_CURTV ; variable SF_CURITEM ; variable SF_CURWIN ; variable SF_CURSET
    set sel [$tv selection]
    if {[llength $sel] == 0} { return }
    set item [lindex $sel 0]
    lassign [$tv item $item -values] rSet rNode rVal
    set SF_CURTV $tv ; set SF_CURITEM $item ; set SF_CURWIN $win ; set SF_CURSET $rSet
    $SFRES.node delete 0 end ; $SFRES.node insert 0 $rNode
    foreach blk [winfo children $SFRES.grid] {
        set otv $blk.tv
        if {[winfo exists $otv] && $otv ne $tv} {
            catch {$otv selection remove [$otv selection]}
        }
    }
    SetStatus "Selected: Win $win / $rSet (node $rNode)"
}

proc ::HVTools::SFRequery {} {
    variable SFRES
    variable SF_CURTV ; variable SF_CURITEM ; variable SF_CURWIN ; variable SF_CURSET
    if {$SF_CURTV eq "" || ![winfo exists $SF_CURTV]} {
        SetStatus "Select a row in a window block first." red
        return
    }
    set newNode [string trim [$SFRES.node get]]
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

# Export / Annotate / Options only — Results now live in the right column
# (BuildResultsPane), shared across both tabs and switched by notebook tab.
proc ::HVTools::BuildToolTab {tab kind} {
    # kind = ms | sf   (ms has the Angle column/field, sf doesn't)
    if {$kind eq "ms"} {
        set ns ::MaxStress
    } else {
        set ns ::SafetyFactor
    }

    # ── Export ──
    labelframe $tab.exp -text " 1. Export (all windows) " -padx 8 -pady 6
    label  $tab.exp.lbl -text "Selection set IDs (space-separated):"
    entry  $tab.exp.ids -width 26
    button $tab.exp.run -text "Run Export" -width 12 \
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
    button $tab.ann.run -text "Annotate" -width 12 \
        -command [expr {$kind eq "ms" ? "::HVTools::MSAnnotate" : "::HVTools::SFAnnotate"}]
    label  $tab.ann.ll -text "Legend TCL (optional — capture styling only):"
    entry  $tab.ann.leg -width 30 -textvariable ${ns}::LEGEND_TCL
    button $tab.ann.bl -text "..." -width 3 -command [list ::HVTools::BrowseLegend $ns]
    label  $tab.ann.lv -text "View list .txt (optional — imports named views, all windows):"
    entry  $tab.ann.view -width 30 -textvariable ${ns}::VIEW_TXT
    button $tab.ann.bv -text "..." -width 3 -command [list ::HVTools::BrowseViewFile $ns]
    button $tab.ann.impview -text "Import Views" -width 12 \
        -command [expr {$kind eq "ms" ? "::HVTools::MSImportViews" : "::HVTools::SFImportViews"}]
    button $tab.ann.capture -text "Capture Images (all windows)" \
        -command [expr {$kind eq "ms" ? "::HVTools::MSCapture" : "::HVTools::SFCapture"}]
    grid $tab.ann.lbl -row 0 -column 0 -sticky w
    grid $tab.ann.id  -row 1 -column 0 -sticky w -pady 2
    grid $tab.ann.run -row 1 -column 1 -padx {6 0}
    grid $tab.ann.ll  -row 2 -column 0 -columnspan 2 -sticky w -pady {6 0}
    grid $tab.ann.leg -row 3 -column 0 -sticky we -pady 2
    grid $tab.ann.bl  -row 3 -column 1 -padx {6 0}
    grid $tab.ann.lv   -row 4 -column 0 -columnspan 2 -sticky w -pady {6 0}
    grid $tab.ann.view -row 5 -column 0 -sticky we -pady 2
    grid $tab.ann.bv   -row 5 -column 1 -padx {6 0}
    grid $tab.ann.impview -row 6 -column 0 -sticky w -pady {4 0}
    grid $tab.ann.capture -row 7 -column 0 -columnspan 2 -sticky we -pady {6 0}
    grid columnconfigure $tab.ann 0 -weight 1
    pack $tab.ann -fill x -padx 8 -pady 4

    # ── Options (Legend / Model Display / Header Note / Measure Note /
    # Re-check — same grouped layout for both tools) ──
    labelframe $tab.opt -text " Options " -padx 6 -pady 6

    labelframe $tab.opt.legend -text "Legend" -padx 6 -pady 4
    checkbutton $tab.opt.legend.on -text "On" -variable ${ns}::SHOW_LEGEND
    pack $tab.opt.legend.on -anchor w

    labelframe $tab.opt.model -text "Model Display" -padx 6 -pady 4
    set elemVar [expr {$kind eq "ms" ? "::HVTools::MS_ELEM" : "::HVTools::SF_ELEM"}]
    ttk::combobox $tab.opt.model.style -width 20 -state readonly -textvariable $elemVar \
        -values [list "Shaded + Mesh Lines" "Shaded + Feature Lines" "Shaded only"]
    button $tab.opt.model.apply -text "Apply Display" -width 12 \
        -command [expr {$kind eq "ms" ? "::HVTools::MSApplyDisplay" : "::HVTools::SFApplyDisplay"}]
    grid $tab.opt.model.style -row 0 -column 0 -sticky w
    grid $tab.opt.model.apply -row 0 -column 1 -sticky w -padx {6 0}

    labelframe $tab.opt.hnote -text "Header Note" -padx 6 -pady 4
    checkbutton $tab.opt.hnote.on -text "On" -variable ${ns}::SHOW_NOTE
    label $tab.opt.hnote.l1 -text "Font size:"
    entry $tab.opt.hnote.size -width 5 -textvariable ${ns}::NOTE_FSIZE
    label $tab.opt.hnote.l2 -text "Precision:"
    entry $tab.opt.hnote.prec -width 4 -textvariable ${ns}::PRECISION
    grid $tab.opt.hnote.on   -row 0 -column 0 -columnspan 4 -sticky w
    grid $tab.opt.hnote.l1   -row 1 -column 0 -sticky w -pady {4 0}
    grid $tab.opt.hnote.size -row 1 -column 1 -sticky w -padx {4 10} -pady {4 0}
    grid $tab.opt.hnote.l2   -row 1 -column 2 -sticky w -pady {4 0}
    grid $tab.opt.hnote.prec -row 1 -column 3 -sticky w -padx {4 0} -pady {4 0}

    labelframe $tab.opt.mnote -text "Measure Note" -padx 6 -pady 4
    checkbutton $tab.opt.mnote.on -text "On" -variable ${ns}::SHOW_MEASURE
    checkbutton $tab.opt.mnote.val -text "Show value" -variable ${ns}::MEA_SHOW_VALUE
    label $tab.opt.mnote.l1 -text "Precision:"
    entry $tab.opt.mnote.prec -width 4 -textvariable ${ns}::MEA_PRECISION
    label $tab.opt.mnote.l2 -text "Size:"
    entry $tab.opt.mnote.size -width 5 -textvariable ${ns}::MEA_FSIZE
    label $tab.opt.mnote.l3 -text "Color (R G B):"
    entry $tab.opt.mnote.color -width 12 -textvariable ${ns}::PINK
    grid $tab.opt.mnote.on    -row 0 -column 0 -sticky w
    grid $tab.opt.mnote.val   -row 0 -column 1 -columnspan 3 -sticky w
    grid $tab.opt.mnote.l1    -row 1 -column 0 -sticky w -pady {4 0}
    grid $tab.opt.mnote.prec  -row 1 -column 1 -sticky w -padx {4 10} -pady {4 0}
    grid $tab.opt.mnote.l2    -row 1 -column 2 -sticky w -pady {4 0}
    grid $tab.opt.mnote.size  -row 1 -column 3 -sticky w -padx {4 0} -pady {4 0}
    grid $tab.opt.mnote.l3    -row 2 -column 0 -sticky w -pady {4 0}
    grid $tab.opt.mnote.color -row 2 -column 1 -columnspan 3 -sticky w -padx {4 0} -pady {4 0}

    # Re-check: pick-only (readonly) — avoids the padding-label trap
    # documented in the lib (typed labels can silently fail to bind data).
    labelframe $tab.opt.recheck -text "Re-check" -padx 6 -pady 4
    label $tab.opt.recheck.l1 -text "Data type:"
    ttk::combobox $tab.opt.recheck.dt -width 22 -state readonly -textvariable ${ns}::DATATYPE
    button $tab.opt.recheck.fetch -text "Fetch lists" -width 10 \
        -command [expr {$kind eq "ms" ? "::HVTools::MSFetchTypes" : "::HVTools::SFFetchTypes"}]
    label $tab.opt.recheck.l2 -text "Component:"
    ttk::combobox $tab.opt.recheck.comp -width 14 -state readonly -textvariable ${ns}::DATACOMP
    grid $tab.opt.recheck.l1    -row 0 -column 0 -sticky w
    grid $tab.opt.recheck.dt    -row 0 -column 1 -sticky w -padx {4 0}
    grid $tab.opt.recheck.fetch -row 0 -column 2 -sticky w -padx {8 0}
    grid $tab.opt.recheck.l2    -row 1 -column 0 -sticky w -pady {4 0}
    grid $tab.opt.recheck.comp  -row 1 -column 1 -sticky w -padx {4 0} -pady {4 0}
    bind $tab.opt.recheck.dt <<ComboboxSelected>> \
        [expr {$kind eq "ms" ? "::HVTools::MSFetchComps" : "::HVTools::SFFetchComps"}]

    grid $tab.opt.legend  -row 0 -column 0 -sticky nwe -pady {0 4}
    grid $tab.opt.model   -row 1 -column 0 -sticky nwe -pady {0 4}
    grid $tab.opt.hnote   -row 2 -column 0 -sticky nwe -pady {0 4}
    grid $tab.opt.mnote   -row 3 -column 0 -sticky nwe -pady {0 4}
    grid $tab.opt.recheck -row 4 -column 0 -sticky nwe
    pack $tab.opt -fill x -padx 8 -pady 4
}

# Builds the results pane (title + top control row + per-window grid)
# inside `res` (a plain frame living in the right column, NOT the notebook
# tab). kind = ms | sf.
proc ::HVTools::BuildResultsPane {res kind} {
    label $res.title -text "3. Results — all windows" -font {-weight bold}
    pack $res.title -anchor w -pady {0 6}

    # ── Top control row: Node ID / (Angle) / Re-query / Refresh / Report ──
    frame $res.hdr
    label $res.hdrl1 -text "Node ID:"
    entry $res.node -width 12
    if {$kind eq "ms"} {
        label $res.hdrl2 -text "Angle:"
        entry $res.ang -width 12
    }
    button $res.requery -text "Re-query Value" \
        -command [expr {$kind eq "ms" ? "::HVTools::MSRequery" : "::HVTools::SFRequery"}]
    button $res.refresh -text "Refresh from CSV" \
        -command [expr {$kind eq "ms" ? "::HVTools::MSLoadResults" : "::HVTools::SFLoadResults"}]
    pack $res.hdrl1  -in $res.hdr -side left
    pack $res.node   -in $res.hdr -side left -padx {4 10}
    if {$kind eq "ms"} {
        pack $res.hdrl2 -in $res.hdr -side left
        pack $res.ang   -in $res.hdr -side left -padx {4 10}
    }
    pack $res.requery -in $res.hdr -side left -padx {0 6}
    pack $res.refresh -in $res.hdr -side left -padx {0 6}
    if {$kind eq "ms"} {
        button $res.report -text "Make Report" -command ::HVTools::MSMakeReport
        pack $res.report -in $res.hdr -side left
    }
    pack $res.hdr -anchor w -pady {0 8}

    # ── Per-window grid (rebuilt by MSLoadResults/SFLoadResults) ──
    frame $res.grid
    pack $res.grid -fill both -expand 1
}

proc ::HVTools::OnTabChanged {} {
    variable W
    variable MSRES
    variable SFRES
    variable HAS_SF
    set sel [$W.nb select]
    if {$HAS_SF && $sel eq $::HVTools::SF} {
        raise $SFRES
    } else {
        raise $MSRES
    }
}

proc ::HVTools::Build {} {
    variable W
    variable MS
    variable SF
    variable MSRES
    variable SFRES
    variable HAS_SF

    catch {destroy $W}
    toplevel $W
    wm title $W "HV Tools — Max Stress / Safety Factor — Nguyen Tan Loc"
    wm attributes $W -topmost 1
    wm resizable $W 1 1

    grid columnconfigure $W 1 -weight 1
    grid rowconfigure    $W 0 -weight 1

    # ── LEFT column: Load section + Notebook (Export/Annotate/Options) ──
    frame $W.left
    grid $W.left -row 0 -column 0 -sticky nsw

    labelframe $W.left.load -text " 0. Load model & results " -padx 8 -pady 6
    label  $W.left.load.lm -text "Model file (shared by all windows):"
    entry  $W.left.load.model -width 40
    button $W.left.load.bm -text "..." -width 3 -command ::HVTools::BrowseModel
    label  $W.left.load.lr -text "Result files (one per line — one window each):"
    text   $W.left.load.res -width 40 -height 12 -yscrollcommand [list $W.left.load.rsb set]
    scrollbar $W.left.load.rsb -orient vertical -command [list $W.left.load.res yview]
    button $W.left.load.br -text "Add..." -width 6 -command ::HVTools::BrowseResults
    frame  $W.left.load.lay
    label  $W.left.load.lay.l -text "Layout:"
    entry  $W.left.load.cols -width 3
    label  $W.left.load.lay.x -text "x"
    entry  $W.left.load.rows -width 3
    label  $W.left.load.lay.hint -text "(ngang x doc)"
    button $W.left.load.run -text "Load All" -width 10 -command ::HVTools::DoLoadAll
    button $W.left.load.reset -text "Reset (New)" -width 10 -command ::HVTools::DoReset

    grid $W.left.load.lm    -row 0 -column 0 -columnspan 2 -sticky w
    grid $W.left.load.model -row 1 -column 0 -sticky we -pady 2
    grid $W.left.load.bm    -row 1 -column 1 -padx {4 0}
    grid $W.left.load.lr    -row 2 -column 0 -columnspan 2 -sticky w -pady {6 0}
    grid $W.left.load.res   -row 3 -column 0 -sticky we -pady 2
    grid $W.left.load.rsb   -row 3 -column 1 -sticky ns
    grid $W.left.load.br    -row 4 -column 0 -sticky w
    grid $W.left.load.lay   -row 5 -column 0 -columnspan 2 -sticky w -pady {6 0}
    pack $W.left.load.lay.l    -in $W.left.load.lay -side left
    pack $W.left.load.cols     -in $W.left.load.lay -side left -padx {4 2}
    pack $W.left.load.lay.x    -in $W.left.load.lay -side left
    pack $W.left.load.rows     -in $W.left.load.lay -side left -padx {2 4}
    pack $W.left.load.lay.hint -in $W.left.load.lay -side left
    grid $W.left.load.reset -row 6 -column 0 -sticky w -pady {6 0}
    grid $W.left.load.run   -row 6 -column 1 -sticky w -pady {6 0}
    grid columnconfigure $W.left.load 0 -weight 1
    pack $W.left.load -fill x -padx 10 -pady {10 4}

    $W.left.load.cols insert 0 "4"
    $W.left.load.rows insert 0 "2"

    # ── Notebook: one tab per tool (Export/Annotate/Options only) ──
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
    pack $W.nb -in $W.left -fill both -expand 1 -padx 10 -pady 4
    bind $W.nb <<NotebookTabChanged>> ::HVTools::OnTabChanged

    # ── RIGHT column: Results (shared, one pane per tool, raised on tab switch) ──
    frame $W.right -padx 10 -pady 10
    grid $W.right -row 0 -column 1 -sticky nsew

    frame $W.right.container
    pack $W.right.container -fill both -expand 1
    frame $W.right.container.ms
    BuildResultsPane $W.right.container.ms ms
    grid $W.right.container.ms -row 0 -column 0 -sticky nsew
    set MSRES $W.right.container.ms

    if {$HAS_SF} {
        frame $W.right.container.sf
        BuildResultsPane $W.right.container.sf sf
        grid $W.right.container.sf -row 0 -column 0 -sticky nsew
        set SFRES $W.right.container.sf
    } else {
        set SFRES $MSRES
    }
    grid columnconfigure $W.right.container 0 -weight 1
    grid rowconfigure    $W.right.container 0 -weight 1
    raise $MSRES

    # ── Status bar (spans both columns) ──
    label $W.status -text "Ready." -anchor w -relief sunken -padx 6
    grid $W.status -row 1 -column 0 -columnspan 2 -sticky we -padx 10 -pady {4 10}

    # Pre-fill tables from existing CSVs
    catch {MSLoadResults}
    if {$HAS_SF} { catch {SFLoadResults} }

    # ── Restore saved paths on open (NO auto-load) ──
    # The last "Load All" config only prefills the fields; loading is
    # always an explicit click on "Load All".
    set cfg [LoadConfig]
    if {$cfg ne ""} {
        lassign $cfg modelFile cols rows resultFiles
        $W.left.load.model delete 0 end ; $W.left.load.model insert 0 $modelFile
        $W.left.load.cols  delete 0 end ; $W.left.load.cols  insert 0 $cols
        $W.left.load.rows  delete 0 end ; $W.left.load.rows  insert 0 $rows
        $W.left.load.res   delete 1.0 end
        foreach rf $resultFiles { $W.left.load.res insert end "$rf\n" }
        SetStatus "Saved paths restored — click Load All when ready."
    }
}

::HVTools::Build
puts "HV Tools panel loaded — window '[wm title $::HVTools::W]' is open."
