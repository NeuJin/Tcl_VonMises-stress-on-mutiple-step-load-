# maxstress_lib.tcl — shared library for the Max Stress tools.
# Procs only: no stdin prompts, no auto-run. Sourced by the console
# wrappers (TCL_StressExport.tcl / TCL_MaxStressAnnotate.tcl) and by the
# panel (MaxStress_Panel.tcl).

namespace eval ::MaxStress {
    variable PINK          "252 62 255"   ;# marker color (GUI read-back)
    variable MEA_FSIZE     15             ;# measure marker text size
    variable NOTE_FSIZE    10             ;# summary note text size
    variable SHOW_NOTE     1              ;# 1 = create the summary note header, 0 = marker only
    variable SHOW_LEGEND   1              ;# legend on/off (ApplyDisplay)
    variable LEGEND_TCL    ""             ;# optional legend TCL sourced per window
                                          ;# during Annotate — capture styling ONLY,
                                          ;# never touches the CSV or results table
    variable NOTE_WHITE    1              ;# 1 = white filled note (left-aligned, bordered,
                                          ;#     leading-space text — doubles as a white pad
                                          ;#     so the axis triad stays readable);
                                          ;# 0 = old transparent right-aligned style
    variable DATATYPE      "S-Stress components"  ;# contour/query data type
    variable DATACOMP      "Mises"                ;# contour/query component
    variable PRECISION     3              ;# decimals for displayed values AND
                                          ;# legend numeric precision (cap 10)
    variable SKIP_PATTERNS {Derived_Case* *Bolt*}
    # Known page-layout preset codes (page SetLayout takes a PRESET INDEX,
    # not a window count). Confirmed via GUI-click + `page GetLayout` on
    # HV14.0: 4x2 -> 19. Add more as they get measured; unknown combos fall
    # back to the runtime probe in LoadAll.
    variable LAYOUT_CODES  [dict create 4x2 19]
    variable LIB_DIR       [file dirname [file normalize [info script]]]
}

# Format a value with the configured number of decimals (fallback 3)
proc ::MaxStress::Fmt {v} {
    variable PRECISION
    set p $PRECISION
    if {![string is integer -strict $p] || $p < 0 || $p > 10} { set p 3 }
    if {[catch {set out [format "%.${p}f" $v]}]} { return $v }
    return $out
}

# Data-type list of a window's model (for the panel droplist).
proc ::MaxStress::FetchTypeList {{winIdx 1}} {
    CleanHandles
    OpenChain
    catch {page SetActiveWindow $winIdx}
    page GetWindowHandle win $winIdx
    win GetClientHandle clt
    clt GetModelHandle model [clt GetActiveModel]
    model GetResultCtrlHandle rctrl
    set dts ""
    if {[catch {set dts [rctrl GetDataTypeList [rctrl GetCurrentSubcase]]}]} {
        catch {set dts [rctrl GetDataTypeList]}
    }
    catch {hwi CloseStack}
    return $dts
}

# Component list for one data type (signature not documented — try variants).
proc ::MaxStress::FetchComponentList {dt {winIdx 1}} {
    CleanHandles
    OpenChain
    catch {page SetActiveWindow $winIdx}
    page GetWindowHandle win $winIdx
    win GetClientHandle clt
    clt GetModelHandle model [clt GetActiveModel]
    model GetResultCtrlHandle rctrl
    set comps ""
    if {[catch {set comps [rctrl GetDataComponentList $dt]}]} {
        if {[catch {set comps [rctrl GetDataComponentList [rctrl GetCurrentSubcase] $dt]}]} {
            catch {set comps [rctrl GetDataComponentList $dt [rctrl GetCurrentSubcase]]}
        }
    }
    catch {hwi CloseStack}
    return $comps
}

# Crank angle from a simulation label like "Step10_Combustion/Angle_1454.99deg:"
# -> "1454.99deg" (substring between the 2nd underscore and the first colon).
proc ::MaxStress::ExtractAngle {simLabel} {
    set pos0 [string first "_" $simLabel]
    set pos1 [string first "_" $simLabel [expr {$pos0 + 1}]]
    set pos2 [string first ":" $simLabel]
    if {$pos1 >= 0 && $pos2 > $pos1} {
        return [string range $simLabel [expr {$pos1 + 1}] [expr {$pos2 - 1}]]
    }
    return "N/A"
}

# Angle comparison tolerant to formatting: "1454.99deg" == "1454.99" == 1454.99
proc ::MaxStress::AngleMatches {a b} {
    if {[string equal -nocase [string trim $a] [string trim $b]]} { return 1 }
    set na "" ; set nb ""
    regexp {[-+]?[0-9]*\.?[0-9]+} $a na
    regexp {[-+]?[0-9]*\.?[0-9]+} $b nb
    if {$na eq "" || $nb eq ""} { return 0 }
    return [expr {abs($na - $nb) < 0.01}]
}

proc ::MaxStress::CleanHandles {} {
    foreach handle {sess proj object page win clt model rctrl sub con leg iso math query vw se sys mea mtmp setc setz mfont note ntmp nfont iter} {
        catch {${handle} ReleaseHandle}
    }
    catch {hwi CloseStack}
}

proc ::MaxStress::OpenChain {} {
    hwi OpenStack
    hwi GetSessionHandle sess
    sess GetProjectHandle proj
    proj GetPageHandle page [proj GetActivePage]
}

# ─────────────────────────────────────────────────────────────────────
# LOAD — set page layout, then load the SAME model file into every
# window with a DIFFERENT result file per window.
# ─────────────────────────────────────────────────────────────────────

proc ::MaxStress::LoadAll {modelFile resultFiles cols rows} {
    if {![file exists $modelFile]} {
        error "model file not found: $modelFile"
    }
    foreach rf $resultFiles {
        if {![file exists $rf]} {
            error "result file not found: $rf"
        }
    }
    if {[llength $resultFiles] == 0} {
        error "no result files given"
    }

    CleanHandles
    OpenChain

    # Page layout — SetLayout takes a PRESET INDEX into the GUI layout-picker
    # grid, NOT a window count (live run: SetLayout 8 produced a 3-window
    # layout). Known codes are used directly (4x2 = 19, GUI-confirmed via
    # page GetLayout); unknown combos fall back to the probe below.
    variable LAYOUT_CODES
    set total [expr {$cols * $rows}]
    set applied 0
    set key "${cols}x${rows}"
    if {[dict exists $LAYOUT_CODES $key]} {
        catch {page SetLayout [dict get $LAYOUT_CODES $key]}
        if {[page GetNumberOfWindows] == $total} {
            set applied 1
            puts "  layout ${key} -> preset [dict get $LAYOUT_CODES $key] (known code)"
        }
    }
    if {$applied} {
        set numWindows $total
    } else {
    # Probe: try each index, keep those whose window count matches
    # cols*rows, then pick the right ORIENTATION (4x2 vs 2x4 both have 8
    # windows) by window 1's graphics width — more columns means narrower
    # windows.
    set candidates {}
    for {set code 1} {$code <= 30} {incr code} {
        if {[catch {page SetLayout $code}]} { continue }
        if {[page GetNumberOfWindows] == $total} {
            set w ""
            catch {
                page GetWindowHandle _lw 1
                set w [_lw GetGraphicsWidth]
                _lw ReleaseHandle
            }
            lappend candidates [list $code $w]
            puts "  layout preset $code -> $total windows (win1 width: $w)"
        }
    }
    if {[llength $candidates] == 0} {
        puts "WARNING: no layout preset gives $total windows — set the layout manually; continuing with [page GetNumberOfWindows]"
    } else {
        set numeric {}
        foreach c $candidates {
            if {[string is double -strict [lindex $c 1]]} { lappend numeric $c }
        }
        if {[llength $numeric] >= 2} {
            set numeric [lsort -real -index 1 $numeric]
            if {$cols >= $rows} {
                set pick [lindex $numeric 0 0]      ;# narrowest win = most columns
            } else {
                set pick [lindex $numeric end 0]    ;# widest win = fewest columns
            }
        } else {
            set pick [lindex $candidates 0 0]
        }
        catch {page SetLayout $pick}
        puts "  -> using layout preset $pick for ${cols}x${rows}"
    }
    set numWindows [page GetNumberOfWindows]
    }
    puts "--- Page has $numWindows window(s); loading [llength $resultFiles] result file(s) ---"

    set winIdx 1
    foreach rf $resultFiles {
        if {$winIdx > $numWindows} {
            puts "WARNING: more result files than windows — '$rf' and beyond skipped"
            break
        }
        puts ""
        puts "===== Window $winIdx ====="
        puts "  result: [file tail $rf]"

        foreach handle {win clt model} {
            catch {${handle} ReleaseHandle}
        }
        catch {page SetActiveWindow $winIdx}
        page GetWindowHandle win $winIdx
        win GetClientHandle clt

        # Clear any model already in this window (re-runnable)
        catch {
            foreach mid [clt GetModelList] {
                catch {clt RemoveModel $mid}
            }
        }

        # HV14-confirmed load pattern: AddModel geometry, then attach results
        clt AddModel $modelFile
        clt GetModelHandle model [clt GetActiveModel]
        model SetResult $rf
        clt Draw
        win ReleaseHandle

        puts "  loaded OK"
        incr winIdx
    }

    catch {hwi CloseStack}
    return $numWindows
}

# ─────────────────────────────────────────────────────────────────────
# DISPLAY — legend on/off + element display mode, every window,
# every component. meshMode: meshlines ("Shaded Elements and Mesh
# Lines") / features ("...and Feature Lines") / none ("Shaded Elements")
# — toolbar buttons = component SetPolygonMode opaque + SetMeshMode
# (console-confirmed mapping).
# ─────────────────────────────────────────────────────────────────────

proc ::MaxStress::ApplyDisplay {legendOn meshMode} {
    CleanHandles
    OpenChain

    set numWindows [page GetNumberOfWindows]
    for {set wi 1} {$wi <= $numWindows} {incr wi} {
        if {[catch {
            foreach handle {win clt model rctrl con leg _comp0 _ch} {
                catch {${handle} ReleaseHandle}
            }
            catch {page SetActiveWindow $wi}
            page GetWindowHandle win $wi
            win GetClientHandle clt
            clt GetModelHandle model [clt GetActiveModel]

            # Legend visibility (both the handle and the display option)
            catch {
                model GetResultCtrlHandle rctrl
                rctrl GetContourCtrlHandle con
                con GetLegendHandle leg
                leg SetVisibility $legendOn
            }
            catch {clt SetDisplayOptions "legend" $legendOn}

            # Element display on every component of the model
            model GetComponentHandle _comp0 0
            set _children [_comp0 GetChildrenList]
            _comp0 ReleaseHandle
            foreach cid $_children {
                catch {
                    model GetComponentHandle _ch $cid
                    _ch SetPolygonMode opaque
                    _ch SetMeshMode $meshMode
                    _ch ReleaseHandle
                }
            }
            clt Draw
            puts "  window $wi: legend=$legendOn, mesh=$meshMode ([llength $_children] components)"
        } err]} {
            puts "!!!! Window $wi display apply failed: $err"
        }
    }
    catch {hwi CloseStack}
}

# ─────────────────────────────────────────────────────────────────────
# EXPORT — max Von Mises sweep over every window on the page
# ─────────────────────────────────────────────────────────────────────

proc ::MaxStress::processWindow {pageHandle winID selectionSets skipPatterns summaryRowsVar} {
    variable DATATYPE
    variable DATACOMP
    variable PRECISION
    upvar 1 $summaryRowsVar summaryRows

    foreach handle {win clt model rctrl sub con leg iso math query vw se sys iter setc setz} {
        catch {${handle} ReleaseHandle}
    }

    # GetWindowHandle takes an INDEX 1..N (confirmed live), not an ID
    $pageHandle GetWindowHandle win $winID
    win GetClientHandle clt
    clt GetModelHandle model [clt GetActiveModel]

    puts ""
    puts "===================================================="
    puts " Window $winID"
    puts "===================================================="

    model GetResultCtrlHandle rctrl
    set subcases [rctrl GetSubcaseList model]
    set numSubcases [llength $subcases]
    set derivedSubcaseID [expr {$numSubcases + 1}]
    set derivedCaseName "Derived_Case_Win${winID}"

    rctrl AddSubcase $derivedCaseName
    rctrl GetSubcaseHandle sub $derivedSubcaseID

    # Iterate the REAL subcase IDs — not 0..N-1 (IDs aren't 0-based).
    foreach sc $subcases {
        # Skip other windows' Derived_Case* (can't derive from derived)
        # and *Bolt* steps (not crank-angle frames).
        set scLabel [rctrl GetSubcaseLabel $sc]
        set skip 0
        foreach pat $skipPatterns {
            if {[string match $pat $scLabel]} { set skip 1 ; break }
        }
        if {$skip} { continue }
        if {[catch {sub AppendSimulation $sc 1} err]} {
            puts "  WARNING window $winID: could not append subcase $sc ($scLabel) into $derivedCaseName: $err"
        }
    }
    sub ReleaseHandle

    puts "--- Derived Case '$derivedCaseName' created ---"

    rctrl GetContourCtrlHandle con
    con GetLegendHandle leg
    rctrl GetIsoValueCtrlHandle iso
    rctrl GetResultMathCtrlHandle math
    model GetQueryCtrlHandle query
    iso SetAverageMode Simple
    win GetViewControlHandle vw
    con GetSelectionSetHandle se
    rctrl GetSystemCtrlHandle sys

    con SetDataType $DATATYPE
    con SetDataComponent $DATACOMP
    con SetAverageMode simple
    con SetCornerDataEnabled true
    con SetEnableState true
    con SetAvgAcrossPartsEnable enable
    set _prec $PRECISION
    if {![string is integer -strict $_prec] || $_prec < 0 || $_prec > 10} { set _prec 3 }
    leg SetNumericPrecision $_prec

    # Frame count = what was ACTUALLY appended (not ID arithmetic, which
    # inflates when windows share a model).
    set derivedSimList [rctrl GetDerivedSimulationList $derivedSubcaseID]
    set numFrames [llength $derivedSimList]
    set subLabel [rctrl GetSubcaseLabel $derivedSubcaseID]
    puts "Subcase name:                     $subLabel"
    puts "Total frames in derived subcase:  $numFrames"

    query SetDataSourceProperty result "Model ID" 1
    query SetDataSourceProperty result "Result Type" $DATATYPE
    query SetDataSourceProperty result "Load Case" $derivedCaseName
    query SetDataSourceProperty result "Component" $DATACOMP
    query SetDataSourceProperty result corners true
    query SetDataSourceProperty result complex real
    query SetDataSourceProperty result complex_format real
    query SetDataSourceProperty result mutiline true
    query SetDataSourceProperty result dataformat csv
    query SetDataSourceProperty result datatype real
    query SetDataSourceProperty result layer all

    puts "Evaluation:      [query GetDataSourceProperty result "Result Type"] - [query GetDataSourceProperty result "Component"]"
    puts "Use corners data:    [query GetDataSourceProperty result corners]"
    puts "Average mode:        [con GetAverageMode]"

    array set maxStress {}
    array set maxNodeID {}
    array set maxSimLabel {}
    array set maxSimID {}

    foreach setID $selectionSets {
        set maxStress($setID) -1e30
        set maxNodeID($setID) ""
        set maxSimLabel($setID) ""
        set maxSimID($setID) ""
    }

    package require Tk
    catch {destroy .status}
    toplevel .status
    wm title .status "Tracking Crank Angles - Window $winID"
    label .status.l -text "Processing frames"
    ttk::progressbar .status.p -length 320 -mode determinate -maximum $numFrames -value 0
    pack .status.l -pady 5
    pack .status.p -padx 10 -pady 8

    for {set frameIdx 1} {$frameIdx <= $numFrames} {incr frameIdx} {

        set pct [expr {int(100.0*$frameIdx/$numFrames)}]
        .status.l configure -text "Window $winID — Frame $frameIdx ($pct%)"
        .status.p configure -value $frameIdx
        update
        after 40

        set frameIdx1 [expr {$frameIdx - 1}]
        rctrl SetCurrentSubcase $derivedSubcaseID
        rctrl SetCurrentSimulation $frameIdx1

        set simLabel [lindex $derivedSimList $frameIdx1]

        foreach setID $selectionSets {
            query SetDataSourceProperty result "Simulation Step" $frameIdx1
            query SetSelectionSet $setID
            query SetQuery "node.id contour.value"
            query GetQuery

            query GetIteratorHandle iter

            for {iter First} {[iter Valid]} {iter Next} {
                set data [iter GetDataList]
                set nodeID [lindex $data 0]
                set stressVal [lindex $data 1]
                if {$stressVal > $maxStress($setID)} {
                    set maxStress($setID) $stressVal
                    set maxNodeID($setID) $nodeID
                    set maxSimLabel($setID) $simLabel
                    set maxSimID($setID) $frameIdx1
                }
            }
            iter ReleaseHandle
        }
    }

    destroy .status

    foreach setID $selectionSets {
        model GetSelectionSetHandle setc $setID
        set setName [setc GetLabel]
        setc ReleaseHandle

        set simLabel $maxSimLabel($setID)
        set angle [ExtractAngle $simLabel]

        set formattedMax [format "%.8f" $maxStress($setID)]
        lappend summaryRows [list $winID $setName $maxNodeID($setID) $formattedMax \
            $maxSimID($setID) $angle $simLabel]
    }

    win ReleaseHandle
    puts "--- Window $winID done ---"
}

# Runs the full export. Returns the summary CSV path.
proc ::MaxStress::RunExport {selectionSets {outputDir ""}} {
    variable SKIP_PATTERNS
    variable LIB_DIR
    if {$outputDir eq ""} { set outputDir $LIB_DIR }

    if {[llength $selectionSets] == 0} {
        error "No selection set IDs given."
    }

    CleanHandles
    OpenChain

    set numWindows [page GetNumberOfWindows]
    puts "--- Found $numWindows window(s) on this page ---"

    set summaryRows {}
    for {set winIdx 1} {$winIdx <= $numWindows} {incr winIdx} {
        if {[catch {processWindow page $winIdx $selectionSets $SKIP_PATTERNS summaryRows} err]} {
            puts ""
            puts "!!!! Window $winIdx failed, skipping it: $err"
            catch {destroy .status}
        }
    }

    # One clean CSV: single header, one row per (window, selection set).
    set summaryFileName [format "%s/Stress_Summary.csv" $outputDir]
    set f [open $summaryFileName w+]
    puts $f "WindowID,SetName,MaxNodeID,MaxStressValue_MPa,SimulationID,CrankAngle_deg,SimulationLabel"
    foreach row $summaryRows {
        lassign $row rWin rSetName rNodeID rStress rSimID rAngle rSimLabel
        puts $f "$rWin,$rSetName,$rNodeID,$rStress,$rSimID,$rAngle,\"$rSimLabel\""
    }
    close $f

    puts ""
    puts "-------------------------------------"
    puts "Exported all frames for $numWindows window(s) to $outputDir"
    puts "Summary: $summaryFileName"
    puts "-------------------------------------"
    catch {hwi CloseStack}
    return $summaryFileName
}

# ─────────────────────────────────────────────────────────────────────
# RE-QUERY — contour value for ONE node at ONE crank angle in ONE window
# (used by the panel's editable results table). Requires the
# Derived_Case_Win<idx> from the export to still exist (same session).
# Returns {stressValue simIdx simLabel angleString}.
# ─────────────────────────────────────────────────────────────────────

proc ::MaxStress::QueryNodeValue {winIdx nodeID angle} {
    variable DATATYPE
    variable DATACOMP
    CleanHandles
    OpenChain

    catch {page SetActiveWindow $winIdx}
    page GetWindowHandle win $winIdx
    win GetClientHandle clt
    set modelID [clt GetActiveModel]
    clt GetModelHandle model $modelID
    model GetResultCtrlHandle rctrl

    # Locate this window's derived case from the export run
    set derivedID ""
    foreach sc [rctrl GetSubcaseList model] {
        if {[rctrl GetSubcaseLabel $sc] eq "Derived_Case_Win${winIdx}"} {
            set derivedID $sc
            break
        }
    }
    if {$derivedID eq ""} {
        catch {hwi CloseStack}
        error "Derived_Case_Win${winIdx} not found — run Export first (same session)"
    }

    # Angle -> simulation index (tolerant match on the numeric part)
    set simList [rctrl GetDerivedSimulationList $derivedID]
    set simIdx -1 ; set simLabel ""
    set i 0
    foreach lbl $simList {
        if {[AngleMatches [ExtractAngle $lbl] $angle]} {
            set simIdx $i
            set simLabel $lbl
            break
        }
        incr i
    }
    if {$simIdx < 0} {
        set avail {}
        foreach lbl $simList { lappend avail [ExtractAngle $lbl] }
        catch {hwi CloseStack}
        error "angle '$angle' not found in window $winIdx — available: $avail"
    }

    rctrl SetCurrentSubcase $derivedID
    rctrl SetCurrentSimulation $simIdx

    # Contour must be the stress contour for contour.value to resolve
    rctrl GetContourCtrlHandle con
    con SetDataType $DATATYPE
    con SetDataComponent $DATACOMP
    con SetAverageMode simple
    con SetCornerDataEnabled true
    con SetEnableState true
    catch {
        page GetAnimatorHandle _anim
        _anim SetCurrentStep [_anim GetCurrentStep]
        _anim ReleaseHandle
    }
    catch {clt SetDisplayOptions "contour" true}
    clt Draw

    # Temp single-node selection set (query needs a set)
    set tid [model AddSelectionSet node]
    model GetSelectionSetHandle _ts $tid
    _ts Add "id == $nodeID"
    set sz 0
    catch {set sz [_ts GetSize]}
    _ts ReleaseHandle
    if {$sz == 0} {
        catch {model RemoveSelectionSet $tid}
        catch {hwi CloseStack}
        error "node $nodeID not found in window $winIdx's model"
    }

    model GetQueryCtrlHandle query
    query SetDataSourceProperty result "Simulation Step" $simIdx
    query SetDataSourceProperty result "Model ID" $modelID
    query SetDataSourceProperty result "Result Type" $DATATYPE
    query SetDataSourceProperty result "Component" $DATACOMP
    query SetDataSourceProperty result "Load Case" "Derived_Case_Win${winIdx}"
    query SetDataSourceProperty result corners true
    query SetDataSourceProperty result complex real
    query SetDataSourceProperty result complex_format real
    query SetDataSourceProperty result mutiline true
    query SetDataSourceProperty result dataformat csv
    query SetDataSourceProperty result datatype real
    query SetDataSourceProperty result layer all
    query SetSelectionSet $tid
    query SetQuery "node.id contour.value"
    query GetQuery

    set val ""
    query GetIteratorHandle iter
    for {iter First} {[iter Valid]} {iter Next} {
        set data [iter GetDataList]
        if {[lindex $data 1] ne ""} { set val [lindex $data 1] }
    }
    iter ReleaseHandle
    catch {model RemoveSelectionSet $tid}

    if {$val eq ""} {
        catch {hwi CloseStack}
        error "no contour value returned for node $nodeID at sim $simIdx (window $winIdx)"
    }

    catch {hwi CloseStack}
    return [list $val $simIdx $simLabel [ExtractAngle $simLabel]]
}

# ─────────────────────────────────────────────────────────────────────
# ANNOTATE — per-window measure marker + summary note from the CSV
# ─────────────────────────────────────────────────────────────────────

proc ::MaxStress::annotateWindow {pageHandle winIdx setID csvRows pink meaSize noteSize} {

    foreach handle {win clt model rctrl mea mtmp setc mfont note ntmp nfont} {
        catch {${handle} ReleaseHandle}
    }

    $pageHandle GetWindowHandle win $winIdx
    win GetClientHandle clt
    clt GetModelHandle model [clt GetActiveModel]
    model GetResultCtrlHandle rctrl

    puts ""
    puts "===== Window $winIdx ====="

    # Resolve set ID -> set name (CSV stores names, not IDs)
    if {[catch {model GetSelectionSetHandle setc $setID} err]} {
        puts "  skip: this window's model has no selection set $setID ($err)"
        return
    }
    set setName [setc GetLabel]
    setc ReleaseHandle

    # Find this window's CSV row
    set nodeID "" ; set simID "" ; set stressVal "" ; set angle "" ; set frameName ""
    foreach row $csvRows {
        lassign $row rWin rSetName rNodeID rStress rSimID rAngle
        if {$rWin == $winIdx && $rSetName eq $setName} {
            set nodeID $rNodeID
            set stressVal $rStress
            set simID $rSimID
            set angle $rAngle
            set rawLabel [string trim [join [lrange $row 6 end] ","] {"}]
            set cpos [string first ":" $rawLabel]
            if {$cpos > 0} {
                set frameName [string range $rawLabel 0 [expr {$cpos - 1}]]
            } else {
                set frameName $rawLabel
            }
            break
        }
    }
    if {$nodeID eq ""} {
        puts "  skip: no CSV row for window $winIdx / set '$setName'"
        return
    }
    puts "  set '$setName' -> node $nodeID, stress $stressVal MPa, sim $simID (angle $angle, frame '$frameName')"

    # Jump to the frame the max was measured on
    set derivedID ""
    foreach sc [rctrl GetSubcaseList model] {
        if {[rctrl GetSubcaseLabel $sc] eq "Derived_Case_Win${winIdx}"} {
            set derivedID $sc
            break
        }
    }
    if {$derivedID ne ""} {
        rctrl SetCurrentSubcase $derivedID
        rctrl SetCurrentSimulation $simID
        puts "  frame set: Derived_Case_Win${winIdx} sim $simID"
    } else {
        puts "  WARNING: Derived_Case_Win${winIdx} not found (session reopened?) — frame NOT changed, value shown may differ from CSV"
    }

    # Optional legend TCL — capture styling only. Sourced AFTER the CSV row
    # was read, so it can never affect stored data or the results table.
    variable LEGEND_TCL
    if {$LEGEND_TCL ne ""} {
        if {![file exists $LEGEND_TCL]} {
            puts "  WARNING: legend TCL not found: $LEGEND_TCL"
        } else {
            catch {rctrl GetContourCtrlHandle con}
            catch {con GetLegendHandle leg}
            if {[catch {uplevel #0 [list source $LEGEND_TCL]} _lerr]} {
                puts "  WARNING: legend TCL failed: $_lerr"
            } else {
                puts "  legend TCL applied: [file tail $LEGEND_TCL]"
            }
        }
    }

    # Remove this script's stale measures (re-runnable)
    set staleIDs {}
    catch {
        foreach mid [clt GetMeasureList] {
            clt GetMeasureHandle mtmp $mid
            if {[string match "MaxStress_*" [mtmp GetLabel]]} {
                lappend staleIDs $mid
            }
            mtmp ReleaseHandle
        }
    }
    foreach mid $staleIDs {
        catch {clt RemoveMeasure $mid}
    }

    # Create the measure marker.
    # ⚠️ Display-mode flags: everything except id must be switched OFF
    # explicitly — "scalar" defaults ON for Nodal Contour measures.
    set mid [clt AddMeasure "Nodal Contour"]
    clt GetMeasureHandle mea $mid
    mea SetLabel "MaxStress_$setName"
    mea AddNode $nodeID
    foreach _flag {label project mag x_comp y_comp z_comp scalar system min max node_path distance prefix} {
        catch {mea SetDisplayMode $_flag false}
    }
    mea SetDisplayMode "id" true
    mea SetColor $pink

    if {![catch {mea GetFontHandle mfont}]} {
        catch {mfont SetSize $meaSize}      ;# SetSize points — console-confirmed
        catch {mfont ReleaseHandle}
    } else {
        puts "  WARNING: mea GetFontHandle failed — font size left at default"
    }

    mea SetVisibility true

    # ── Summary note (toggleable via ::MaxStress::SHOW_NOTE) ──
    # Pre-existing window notes (e.g. templex "Model Info") are kept but
    # HIDDEN (only while our note is enabled); this script's own
    # MaxStress_* notes are always removed first — so annotating with the
    # toggle OFF also CLEARS old note headers.
    variable SHOW_NOTE
    set staleNotes {}
    set cornerPos ""
    catch {
        foreach nid [clt GetNoteList] {
            clt GetNoteHandle ntmp $nid
            set nname ""
            catch {set nname [ntmp GetName]}
            if {$nname eq ""} { catch {set nname [ntmp GetLabel]} }
            if {[string match "MaxStress_*" $nname]} {
                lappend staleNotes $nid
            } elseif {$SHOW_NOTE} {
                if {$cornerPos eq ""} {
                    catch {set cornerPos [ntmp GetPosition]}
                }
                catch {ntmp SetVisibility false}
            }
            ntmp ReleaseHandle
        }
    }
    foreach nid $staleNotes {
        catch {clt RemoveNote $nid}
    }

    if {!$SHOW_NOTE} {
        clt Draw
        puts "  measure 'MaxStress_$setName' created (id $mid), note header OFF"
        return
    }

    set nid [clt AddNote 0]
    clt GetNoteHandle note $nid            ;# handle NAME first, then id
    catch {note SetName  "MaxStress_$setName"}
    catch {note SetLabel "MaxStress_$setName"}
    if {$angle ne "" && $angle ne "N/A"} {
        set line1 "Angle: $angle"
    } else {
        set line1 "Frame: $frameName"
    }
    set stress3 [Fmt $stressVal]
    variable NOTE_WHITE
    if {$NOTE_WHITE} {
        # White filled style. Big left padding leaves a white area for the
        # axis triad to render on; the first line starts with "." because
        # HV auto-trims leading whitespace on line 1 (the dot anchors the
        # indent), and every line is padded to the same column so all 3
        # lines align.
        note SetText ".                  $line1\n                   Node ID: $nodeID\n                   MAX: $stress3 MPa"
        catch {note SetAlignment left}
        catch {note SetBorderThickness 1}
        catch {note SetTransparency false}
        catch {note SetBackgroundColor "255 255 255"}
    } else {
        note SetText "$line1\nNode ID: $nodeID\nMax Stress: $stress3 MPa"
        catch {note SetAlignment right}
        catch {note SetBorderThickness 0}
        catch {note SetTransparency true}
    }
    catch {note SetScreenAnchor true}
    if {$NOTE_WHITE} {
        # Bottom-left placement (white pad sits under the triad).
        # SetPosition's coordinate system is undocumented — sniff it from
        # GetPosition: values <= 1 treated as normalized (origin assumed
        # top-left), larger as pixels sized from the window graphics area.
        set curPos ""
        catch {set curPos [note GetPosition]}
        set placed 0
        if {[llength $curPos] >= 2} {
            lassign $curPos px py
            if {[string is double -strict $px] && [string is double -strict $py]} {
                if {$px <= 1.0 && $py <= 1.0} {
                    if {![catch {note SetPosition "0.02 0.97"}]} { set placed 1 }
                } else {
                    set gh ""
                    catch {set gh [win GetGraphicsHeight]}
                    if {$gh ne "" && ![catch {note SetPosition "10 [expr {int($gh) - 20}]"}]} {
                        set placed 1
                    }
                }
            }
        }
        set rb ""
        catch {set rb [note GetPosition]}
        puts "  note position: '$curPos' -> '$rb' (placed=$placed)"
    } elseif {$cornerPos ne ""} {
        # Old style: reuse the hidden built-in note's corner spot
        if {[catch {note SetPosition $cornerPos} err]} {
            puts "  WARNING: SetPosition '$cornerPos' failed: $err"
        }
    }
    if {![catch {note GetFontHandle nfont}]} {
        catch {nfont SetSize $noteSize}
        catch {nfont ReleaseHandle}
    }
    note SetVisibility true

    clt Draw
    puts "  measure 'MaxStress_$setName' created (id $mid), note id $nid"
}

# Runs the full annotation pass for ONE selection set ID.
proc ::MaxStress::RunAnnotate {setID {outputDir ""}} {
    variable PINK
    variable MEA_FSIZE
    variable NOTE_FSIZE
    variable LIB_DIR
    if {$outputDir eq ""} { set outputDir $LIB_DIR }

    if {[string trim $setID] eq ""} {
        error "No selection set ID given."
    }
    set setID [lindex [split [string trim $setID]] 0]

    set csvFile "$outputDir/Stress_Summary.csv"
    if {![file exists $csvFile]} {
        error "Summary CSV not found: $csvFile — run the export first."
    }

    set f [open $csvFile r]
    set csvRows {}
    set lineNo 0
    while {[gets $f line] >= 0} {
        incr lineNo
        if {$lineNo == 1} { continue }
        if {[string trim $line] eq ""} { continue }
        set fields [split $line ","]
        if {[llength $fields] < 6} { continue }
        lappend csvRows $fields
    }
    close $f
    puts "--- Loaded [llength $csvRows] row(s) from $csvFile ---"

    CleanHandles
    OpenChain

    set numWindows [page GetNumberOfWindows]
    puts "--- Found $numWindows window(s) on this page ---"

    for {set winIdx 1} {$winIdx <= $numWindows} {incr winIdx} {
        if {[catch {annotateWindow page $winIdx $setID $csvRows $PINK $MEA_FSIZE $NOTE_FSIZE} err]} {
            puts ""
            puts "!!!! Window $winIdx failed, skipping it: $err"
        }
    }

    puts ""
    puts "################  Annotation done.  ################"
    catch {hwi CloseStack}
}
