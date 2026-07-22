# maxstress_lib.tcl — shared library for the Max Stress tools.
# Procs only: no stdin prompts, no auto-run. Sourced by the console
# wrappers (TCL_StressExport.tcl / TCL_MaxStressAnnotate.tcl) and by the
# panel (MaxStress_Panel.tcl).

namespace eval ::MaxStress {
    variable PINK          "252 62 255"   ;# marker color (GUI read-back)
    variable MEA_FSIZE     15             ;# measure marker text size
    variable NOTE_FSIZE    10             ;# summary note text size
    variable SHOW_NOTE     1              ;# 1 = create the summary note header, 0 = marker only
    variable SHOW_MEASURE  1              ;# 1 = create the node-ID marker, 0 = note only
    variable MEA_SHOW_VALUE 0             ;# 1 = also show the value on the marker (scalar flag)
    variable MEA_PRECISION 3              ;# decimals for the marker's own value (mea SetNumericPrecision)
    variable SHOW_LEGEND   1              ;# legend on/off (ApplyDisplay)
    variable LEGEND_TCL    ""             ;# optional legend TCL sourced per window
                                          ;# during Annotate — capture styling ONLY,
                                          ;# never touches the CSV or results table
    variable VIEW_TXT      ""             ;# optional *ViewName/*Matrix view-list .txt,
                                          ;# imported (SaveView) into every window
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

# Writes to disk immediately (open/puts/flush/close every call) so the
# last few lines survive even if HW crashes and takes the Tcl console
# down with it before anyone can read/screenshot it. Used to pinpoint
# which HV API call was in flight when a native crash happens.
proc ::MaxStress::DebugLog {msg} {
    catch {
        set fh [open {C:/temp/hvtools_load_debug.log} a]
        puts $fh "[clock format [clock seconds] -format {%H:%M:%S}] $msg"
        flush $fh
        close $fh
    }
}

# ─────────────────────────────────────────────────────────────────────
# LOAD — set page layout, then load each window's own self-contained
# ODB directly. The .inp model file is NO LONGER loaded into HV (its
# separate attach-results step crashes 2025.1) — instead it is parsed
# as plain text for its *NSET blocks, and those node sets are
# recreated as HV selection sets in every window. This keeps the
# user's workflow: edit the .inp text to add a query region, reload —
# no solver re-run, no manual node picking, and no SetResult call.
# ─────────────────────────────────────────────────────────────────────

# Parse every *NSET block out of an Abaqus .inp (plain text). Returns
# a dict: set name -> flat list of node ids. Handles both explicit
# comma-separated id lists (wrapped over any number of lines) and the
# GENERATE form (first, last, increment). Skips ** comment lines.
# A data token that isn't a number but matches an earlier set name is
# treated as a set reference and merged (Abaqus allows nested NSETs).
proc ::MaxStress::ParseInpNodeSets {inpFile} {
    set sets [dict create]
    set fh [open $inpFile r]
    set cur ""
    set gen 0
    while {[gets $fh line] >= 0} {
        set t [string trim $line]
        if {$t eq "" || [string range $t 0 1] eq "**"} { continue }
        if {[string index $t 0] eq "*"} {
            set cur ""
            set gen 0
            set parts [split $t ,]
            set kw [string toupper [string trim [lindex $parts 0]]]
            if {$kw eq "*NSET"} {
                foreach p [lrange $parts 1 end] {
                    set p [string trim $p]
                    if {[string match -nocase "NSET=*" $p]} {
                        set cur [string trim [string range $p 5 end] { \"'}]
                    } elseif {[string equal -nocase "GENERATE" $p]} {
                        set gen 1
                    }
                }
                if {$cur ne "" && ![dict exists $sets $cur]} {
                    dict set sets $cur {}
                }
            }
            continue
        }
        if {$cur eq ""} { continue }
        set ids [dict get $sets $cur]
        if {$gen} {
            set f "" ; set l "" ; set inc 1
            set vals {}
            foreach x [split $t ,] {
                set x [string trim $x]
                if {$x ne ""} { lappend vals $x }
            }
            lassign $vals f l inc
            if {$inc eq "" || $inc == 0} { set inc 1 }
            if {[string is integer -strict $f] && [string is integer -strict $l]} {
                for {set n $f} {$n <= $l} {incr n $inc} { lappend ids $n }
            }
        } else {
            foreach x [split $t ,] {
                set x [string trim $x]
                if {$x eq ""} { continue }
                if {[string is integer -strict $x]} {
                    lappend ids $x
                } elseif {[dict exists $sets $x]} {
                    lappend ids {*}[dict get $sets $x]
                }
            }
        }
        dict set sets $cur $ids
    }
    close $fh
    return $sets
}

# Recreate parsed .inp node sets as HV node selection sets on the
# CURRENT `model` handle. Skips names the model already has (ODBs
# carry a few solver-written sets; also makes LoadAll re-runnable
# without duplicates). Verifies each set via GetSize readback — a
# size of 0 with a non-empty id list means the ids didn't resolve in
# this model (wrong pool/instance ids) and is logged as a warning.
proc ::MaxStress::CreateNodeSets {inpSets} {
    set existing {}
    catch {
        foreach sid [model GetSelectionSetList] {
            catch {
                model GetSelectionSetHandle _exsh $sid
                lappend existing [_exsh GetLabel]
                _exsh ReleaseHandle
            }
        }
    }
    set made 0
    dict for {name ids} $inpSets {
        if {[llength $ids] == 0} { continue }
        if {[lsearch -exact $existing $name] >= 0} {
            puts "    set '$name': already in model — kept as-is"
            continue
        }
        if {[catch {
            set _nid [model AddSelectionSet node]
            model GetSelectionSetHandle _nsh $_nid
            _nsh SetLabel $name
            foreach n $ids {
                catch {_nsh Add "id == $n"}
            }
            set _sz [_nsh GetSize]
            _nsh ReleaseHandle
            if {$_sz == 0} {
                puts "    WARNING: set '$name' resolved 0/[llength $ids] nodes — ids may not match this model"
            } else {
                puts "    set '$name': $_sz/[llength $ids] nodes"
            }
            DebugLog "  set '$name' created: $_sz/[llength $ids] nodes"
            incr made
        } _serr]} {
            puts "    WARNING: creating set '$name' failed: $_serr"
            DebugLog "  set '$name' FAILED: $_serr"
        }
    }
    return $made
}

# List the CURRENT model's selection sets as a flat {id label ...}
# table (also printed for diagnostics). Same shape as SafetyFactor's.
proc ::MaxStress::ListSets {} {
    set out {}
    catch {
        foreach sid [model GetSelectionSetList] {
            model GetSelectionSetHandle _msls $sid
            set lbl [_msls GetLabel]
            set sz  ""
            catch {set sz [_msls GetSize]}
            _msls ReleaseHandle
            puts "    set id $sid -> '$lbl' (size $sz)"
            lappend out $sid $lbl
        }
    }
    return $out
}

# Resolve user input (a real ID or a set NAME) against a ListSets table.
# Returns the real ID, or "" if no match. Needed since the direct-ODB
# load: set IDs now depend on how many solver-written sets the ODB
# carries, so the stable way to address a set is its NSET name.
proc ::MaxStress::ResolveSet {input setTable} {
    foreach {sid lbl} $setTable {
        if {$sid eq $input} { return $sid }
    }
    foreach {sid lbl} $setTable {
        if {[string equal -nocase $lbl $input]} { return $sid }
    }
    return ""
}

# Reset the whole session (File > New equivalent) — clears every window,
# model and result. Run this before Load All when swapping result sets;
# reloading into non-empty windows can hang on a hidden confirm dialog.
proc ::MaxStress::ResetSession {} {
    CleanHandles
    hwi OpenStack
    hwi GetSessionHandle sess
    set r [catch {sess New} err]
    catch {hwi CloseStack}
    if {$r} {
        error "sess New failed: $err"
    }
    puts "--- Session reset (sess New) — all windows cleared ---"
}

proc ::MaxStress::LoadAll {modelFile resultFiles cols rows} {
    if {![file exists $modelFile]} {
        error "model file not found: $modelFile"
    }
    if {[llength $resultFiles] == 0} {
        error "no result files given"
    }
    # Missing result files are logged and SKIPPED — the rest still load.
    set okFiles {}
    set nMissing 0
    foreach rf $resultFiles {
        if {![file exists $rf]} {
            puts "WARNING: result file not found — skipped: $rf"
            incr nMissing
        } else {
            lappend okFiles $rf
        }
    }
    if {[llength $okFiles] == 0} {
        error "none of the [llength $resultFiles] result files exist"
    }
    set resultFiles $okFiles

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
    DebugLog "LoadAll: $numWindows window(s), [llength $resultFiles] result file(s), model=$modelFile"

    # Node sets come from the .inp as TEXT (parsed once, recreated in
    # every window) — the .inp itself is never loaded into HV on this
    # path. See the section comment above for why (2025.1 SetResult
    # crash).
    set inpSets [dict create]
    if {[string match -nocase "*.inp" $modelFile]} {
        if {[catch {set inpSets [ParseInpNodeSets $modelFile]} _perr]} {
            puts "WARNING: could not parse node sets from $modelFile — $_perr"
            DebugLog "ParseInpNodeSets FAILED: $_perr"
        } else {
            set _names [dict keys $inpSets]
            puts "  parsed [llength $_names] node set(s) from .inp: $_names"
            DebugLog "ParseInpNodeSets: [llength $_names] set(s): $_names"
        }
    }

    set winIdx 1
    foreach rf $resultFiles {
        if {$winIdx > $numWindows} {
            puts "WARNING: more result files than windows — '$rf' and beyond skipped"
            break
        }
        puts ""
        puts "===== Window $winIdx ====="
        puts "  result: [file tail $rf]"
        DebugLog "Window $winIdx: begin (result=[file tail $rf])"

        if {[catch {

        # Full stack reset per window (NOT just releasing win/clt/model) —
        # same fix that solved "view import only applied to window 1" in
        # ImportViewsIntoWindow. A single long-lived hwi OpenStack spanning
        # all N windows apparently accumulates stale state that a plain
        # per-handle ReleaseHandle doesn't fully clear, crashing HW 2025.1
        # partway through (observed: always window 3, regardless of which
        # result file is there — position-dependent, not data-dependent).
        foreach handle {rctrl model clt win page proj sess} {
            catch {${handle} ReleaseHandle}
        }
        catch {hwi CloseStack}
        hwi OpenStack
        hwi GetSessionHandle sess
        sess GetProjectHandle proj
        proj GetPageHandle page [proj GetActivePage]
        DebugLog "Window $winIdx: handles released"
        catch {page SetActiveWindow $winIdx}
        DebugLog "Window $winIdx: SetActiveWindow done"
        page GetWindowHandle win $winIdx
        DebugLog "Window $winIdx: GetWindowHandle done"
        win GetClientHandle clt
        DebugLog "Window $winIdx: GetClientHandle done"

        # Clear any model already in this window (re-runnable). GetModelList
        # may not exist on every HV version — fall back to popping the
        # active model until none is left, and LOG what happened so a
        # failed clear is visible instead of silently hanging AddModel.
        set _mlist ""
        catch {set _mlist [clt GetModelList]}
        if {$_mlist ne ""} {
            foreach mid $_mlist {
                catch {clt RemoveModel $mid}
            }
            puts "  cleared models (list): $_mlist"
        } else {
            set _prev ""
            set _cleared 0
            for {set _k 0} {$_k < 8} {incr _k} {
                set _am ""
                catch {set _am [clt GetActiveModel]}
                if {$_am eq "" || $_am eq $_prev} { break }
                set _prev $_am
                if {[catch {clt RemoveModel $_am}]} { break }
                incr _cleared
            }
            puts "  cleared models (fallback): $_cleared"
        }
        DebugLog "Window $winIdx: old models cleared"

        # ⚠️ 2026-07-16, HW 2025.1: the old two-step pattern (AddModel the
        # shared .inp geometry, then `model SetResult $rf` to attach each
        # window's own result file) crashes HW natively — confirmed via
        # DebugLog + live testing to be the SetResult call specifically,
        # reproduced identically via pure manual GUI "Load Results" (no TCL
        # at all), always within the first few uses regardless of how many
        # models/windows already exist. The user's .odb files are confirmed
        # self-contained (full geometry + results in one file — Abaqus ODB
        # "Case A" per HV14/2022/2024 reference), so AddModel can load $rf
        # directly, skipping SetResult (and $modelFile) entirely. This
        # avoids the buggy code path outright rather than working around it.
        DebugLog "Window $winIdx: calling clt AddModel $rf (direct, self-contained ODB)"
        clt AddModel $rf
        DebugLog "Window $winIdx: AddModel returned OK"
        clt GetModelHandle model [clt GetActiveModel]
        # ⚠️ Live 2025.1 finding: AddModel alone loads GEOMETRY ONLY here
        # (window title stayed "N/A : Model Step", export found no
        # subcases, CSV came out empty) — despite the HV14 "Case A" doc
        # saying a self-contained ODB loads results too, and despite the
        # GUI's combined Model+Results load working fine 8/8. So attach
        # the same ODB's results explicitly — via AddResult (the
        # multi-result attach API), NOT SetResult (the replace-result
        # API whose code path natively crashes 2025.1, see above).
        set _resChk ""
        catch {set _resChk [model GetResultFileName]}
        DebugLog "Window $winIdx: GetResultFileName after AddModel -> '$_resChk'"
        if {$_resChk eq ""} {
            DebugLog "Window $winIdx: calling model AddResult $rf"
            if {[catch {model AddResult $rf} _arerr]} {
                DebugLog "Window $winIdx: AddResult FAILED - $_arerr"
                puts "  WARNING: AddResult failed: $_arerr"
            } else {
                DebugLog "Window $winIdx: AddResult returned OK"
            }
            set _resChk ""
            catch {set _resChk [model GetResultFileName]}
            DebugLog "Window $winIdx: GetResultFileName after AddResult -> '$_resChk'"
        }
        if {$_resChk eq ""} {
            puts "  WARNING: no results attached — export will find no subcases in this window"
        }
        # GetResultFileName reporting a path only proves the REFERENCE
        # was registered — live 2025.1 run showed the loadcases still
        # weren't available afterwards (window stuck on "Model Step").
        # 2025.1 loads result data asynchronously ("Upfront Data
        # Loading"), so block until done, then read back the ACTUAL
        # subcase count, and activate the first real subcase so the
        # window leaves the geometry-only "Model Step" state.
        DebugLog "Window $winIdx: calling clt WaitForResults"
        catch {clt WaitForResults}
        set _scList {}
        catch {
            model GetResultCtrlHandle rctrl
            set _scList [rctrl GetSubcaseList model]
        }
        DebugLog "Window $winIdx: subcase count after load = [llength $_scList] ($_scList)"
        if {[llength $_scList] == 0} {
            puts "  WARNING: 0 loadcases available — result DATA did not load (reference only)"
        } else {
            puts "  [llength $_scList] loadcase(s) available"
            catch {
                rctrl SetCurrentSubcase [lindex $_scList 0]
                rctrl SetCurrentSimulation 0
            }
            catch {
                page GetAnimatorHandle _anim
                catch {_anim SetCurrentStep 0}
                _anim ReleaseHandle
            }
        }
        catch {rctrl ReleaseHandle}
        if {[dict size $inpSets] > 0} {
            DebugLog "Window $winIdx: creating [dict size $inpSets] node set(s) from .inp"
            CreateNodeSets $inpSets
        }
        DebugLog "Window $winIdx: calling clt Draw"
        clt Draw
        DebugLog "Window $winIdx: Draw returned OK"
        win ReleaseHandle

        puts "  loaded OK"
        DebugLog "Window $winIdx: loaded OK"

        } _werr]} {
            puts "!!!! Window $winIdx load failed — skipped: $_werr"
            DebugLog "Window $winIdx: FAILED - $_werr"
        }
        incr winIdx
    }
    if {$nMissing > 0} {
        puts ""
        puts "NOTE: $nMissing result file(s) were missing and skipped (see WARNINGs above)"
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
    # ⚠️ HV wants the literal string "true"/"false" for leg SetVisibility —
    # a Tk checkbutton's -variable holds "1"/"0" by default, which HV
    # silently ignores (no error, legend just never toggles). Normalize.
    set legendOn [expr {$legendOn ? "true" : "false"}]

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

    # Resolve each requested set (ID or NAME) against THIS window's
    # model. With the direct-ODB load, numeric IDs shift depending on
    # how many solver-written sets the ODB carries — so unresolvable
    # tokens are warned + skipped per window rather than killing the
    # whole window's rows.
    set _setTable [ListSets]
    set _resolved {}
    foreach _tok $selectionSets {
        set _rid [ResolveSet $_tok $_setTable]
        if {$_rid eq ""} {
            puts "  WARNING window $winID: no set matching '$_tok' (see list above) — skipped"
        } else {
            lappend _resolved $_rid
        }
    }
    if {[llength $_resolved] == 0} {
        error "none of the requested sets ($selectionSets) exist in window $winID's model"
    }
    set selectionSets $_resolved

    model GetResultCtrlHandle rctrl
    set subcases [rctrl GetSubcaseList model]
    set numSubcases [llength $subcases]
    set derivedCaseName "Derived_Case_Win${winID}"

    rctrl AddSubcase $derivedCaseName

    # ⚠️ derivedSubcaseID used to be a guess (numSubcases+1) — confirmed
    # WRONG on 2025.1's direct-ODB-loaded model (AddSubcase does not
    # necessarily assign the next integer id): GetSubcaseHandle on the
    # guessed id silently failed to create "sub" (no error raised), so
    # every later `sub AppendSimulation` threw "invalid command name
    # sub" for every frame. Read the subcase list back AFTER AddSubcase
    # and take the one id that wasn't there before — the real,
    # confirmed id, whatever numbering scheme this model actually uses.
    set subcasesAfter [rctrl GetSubcaseList model]
    set newIDs {}
    foreach sc $subcasesAfter {
        if {[lsearch -exact $subcases $sc] < 0} { lappend newIDs $sc }
    }
    if {[llength $newIDs] != 1} {
        error "AddSubcase '$derivedCaseName' did not yield exactly one new subcase id (got: $newIDs) — before=$subcases after=$subcasesAfter"
    }
    set derivedSubcaseID [lindex $newIDs 0]
    DebugLog "Window $winID: derived subcase '$derivedCaseName' real id=$derivedSubcaseID (old guess would have been [expr {$numSubcases+1}])"

    rctrl GetSubcaseHandle sub $derivedSubcaseID
    if {[llength [info commands sub]] == 0} {
        error "GetSubcaseHandle silently failed to create 'sub' for id $derivedSubcaseID — cannot append frames"
    }

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
    # ⚠️ Legend numeric precision affects the QUERIED value on this HV
    # build, not just its display — setting it low during the sweep was
    # silently rounding the max stress before it ever reached the CSV, so
    # the panel's Precision option (a display-only setting) could never
    # "add back" lost decimals. Always extract at max precision; PRECISION
    # only controls how the already-full-precision value is FORMATTED
    # later (Fmt: CSV write still uses raw %.8f, note/report/table use Fmt).
    leg SetNumericPrecision 8

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

# Pivoted report CSV shaped like the Excel master table: one column group
# per window (Node ID | Stress | Angle), one row per set, windows banded
# groupCols at a time (band = one row of the page layout). PURE FILE
# OPERATION — reads Stress_Summary.csv and re-lays it out; completely
# independent from the export run (no HyperView calls at all). Column
# labels come from the result file names saved in maxstress_config.txt
# when available, else "Win N".
proc ::MaxStress::MakeReport {{outputDir ""} {groupCols 4}} {
    variable LIB_DIR
    if {$outputDir eq ""} { set outputDir $LIB_DIR }
    set csvFile [file join $outputDir "Stress_Summary.csv"]
    if {![file exists $csvFile]} {
        error "Summary CSV not found: $csvFile — run Export first."
    }

    array set D {}
    set winsSeen {}
    set setsSeen {}
    set cf [open $csvFile r]
    set lineNo 0
    while {[gets $cf line] >= 0} {
        incr lineNo
        if {$lineNo == 1 || [string trim $line] eq ""} { continue }
        set fields [split $line ","]
        if {[llength $fields] < 6} { continue }
        lassign $fields w s node stressv simid angle
        set D($w,$s) [list $node $stressv $angle]
        if {[lsearch -exact $winsSeen $w] < 0} { lappend winsSeen $w }
        if {[lsearch -exact $setsSeen $s] < 0} { lappend setsSeen $s }
    }
    close $cf
    if {[llength $winsSeen] == 0} {
        error "no data rows in $csvFile"
    }

    # Window labels from the saved Load-All config (result file basenames)
    array set LBL {}
    catch {
        set cfgFile [file join $outputDir "maxstress_config.txt"]
        if {[file exists $cfgFile]} {
            set cf [open $cfgFile r]
            set lines {}
            while {[gets $cf line] >= 0} {
                if {[string trim $line] ne ""} { lappend lines $line }
            }
            close $cf
            set i 1
            foreach rf [lrange $lines 2 end] {
                set LBL($i) [file rootname [file tail $rf]]
                incr i
            }
        }
    }

    if {$groupCols < 1} { set groupCols 4 }
    set reportFile [file join $outputDir "Stress_Report.csv"]
    set f [open $reportFile w]

    for {set start 0} {$start < [llength $winsSeen]} {incr start $groupCols} {
        set band [lrange $winsSeen $start [expr {$start + $groupCols - 1}]]

        # Header row 1: window/case labels spanning 3 columns each
        set h1 ""
        foreach w $band {
            set lbl "Win $w"
            if {[info exists LBL($w)]} { set lbl $LBL($w) }
            append h1 ",$lbl,,"
        }
        puts $f $h1
        # Header row 2: sub-columns
        set h2 "Set"
        foreach w $band {
            append h2 ",Node ID,Stress\[MPa\],Angle\[deg\]"
        }
        puts $f $h2

        foreach s $setsSeen {
            set line $s
            foreach w $band {
                if {[info exists D($w,$s)]} {
                    lassign $D($w,$s) node stressv angle
                    set angNum ""
                    regexp {[-+]?[0-9]*\.?[0-9]+} $angle angNum
                    append line ",$node,[Fmt $stressv],$angNum"
                } else {
                    append line ",,,"
                }
            }
            puts $f $line
        }
        puts $f ""
    }
    close $f
    puts "Report:  $reportFile"
    return $reportFile
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
        if {[catch {_anim SetCurrentStep $simIdx}]} {
            _anim SetCurrentStep [_anim GetCurrentStep]
        }
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
# VIEW IMPORT — parse a *ViewName/*ProjectionType/*Matrix/*ClippingRegion
# .txt export (blocks separated by lines of '#') and register every view
# as a NAMED VIEW (vw SaveView) in every window, so it can be recalled
# later with `vw RestoreView <name>` for a deterministic camera angle
# independent of window size (see the earlier win-size gotchas in the
# HW14 library).
# ─────────────────────────────────────────────────────────────────────

proc ::MaxStress::ParseViewFile {path} {
    set views {}
    set f [open $path r]
    set curName "" ; set curProj "" ; set curMatrix "" ; set curClip ""
    while {[gets $f line] >= 0} {
        set trimmed [string trim $line]
        if {$trimmed eq "" } { continue }
        if {[string match "#*" $trimmed]} {
            if {$curName ne ""} {
                lappend views [list $curName $curProj $curMatrix $curClip]
            }
            set curName "" ; set curProj "" ; set curMatrix "" ; set curClip ""
            continue
        }
        set toks [regexp -all -inline {\S+} $trimmed]
        set key [lindex $toks 0]
        switch -- $key {
            "*ViewName"       { set curName [lindex $toks 1] }
            "*ProjectionType" { set curProj [lindex $toks 1] }
            "*Matrix"         { set curMatrix [lrange $toks 1 end] }
            "*ClippingRegion" { set curClip   [lrange $toks 1 end] }
        }
    }
    if {$curName ne ""} {
        lappend views [list $curName $curProj $curMatrix $curClip]
    }
    close $f
    return $views
}

# Imports the whole parsed view list into ONE window (all named views —
# no per-window matching, every window gets the same view library).
# ⚠️ This is the only proc in the whole tool that re-grabs `vw` across a
# window loop (every other per-window loop only cycles win/clt/model/
# con/leg) — a plain release+regrab of `vw` was found to silently keep
# pointing at window 1 for windows 2+ (the classic "handle already
# exists, swallowed by catch" trap). Fixed with a full hwi CloseStack/
# OpenStack + re-grab of sess/proj/page on EVERY window, matching the
# "mandatory" reset documented for the handle chain.
proc ::MaxStress::ImportViewsIntoWindow {winIdx views} {
    catch {vw ReleaseHandle} ; catch {win ReleaseHandle}
    catch {proj ReleaseHandle} ; catch {sess ReleaseHandle}
    catch {hwi CloseStack}
    hwi OpenStack
    hwi GetSessionHandle sess
    sess GetProjectHandle proj
    proj GetPageHandle page [proj GetActivePage]
    page GetWindowHandle win $winIdx
    win GetViewControlHandle vw

    set n 0
    foreach v $views {
        lassign $v name proj_ matrix clip
        if {$name eq ""} { continue }
        catch {vw SetProjectionType $proj_}
        if {[llength $matrix] == 16} { catch {vw SetViewMatrix $matrix} }
        if {[llength $clip] >= 4}    { catch {vw SetViewVolume $clip} }
        if {![catch {vw SaveView $name}]} { incr n }
    }
    set active ""
    catch {set active [vw GetActiveView]}
    puts "  window $winIdx: imported $n/[llength $views] view(s) (active view now: '$active')"
    return $n
}

proc ::MaxStress::RunImportViews {viewFile} {
    if {![file exists $viewFile]} {
        error "view file not found: $viewFile"
    }
    set views [ParseViewFile $viewFile]
    if {[llength $views] == 0} {
        error "no views parsed from $viewFile — check the *ViewName/*Matrix format"
    }

    CleanHandles
    OpenChain
    set numWindows [page GetNumberOfWindows]
    set total 0
    for {set wi 1} {$wi <= $numWindows} {incr wi} {
        if {[catch {ImportViewsIntoWindow $wi $views} n]} {
            puts "!!!! Window $wi view import failed: $n"
        } else {
            incr total $n
        }
    }
    catch {vw ReleaseHandle} ; catch {win ReleaseHandle}
    catch {hwi CloseStack}
    puts "--- Imported [llength $views] view(s) into $numWindows window(s) ($total total saves) ---"
    return [list $numWindows [llength $views]]
}

# ─────────────────────────────────────────────────────────────────────
# CAPTURE — screenshot every window, filename = SetName_WinID_NodeID.png
# Uses the same CSV row resolution as annotateWindow but only captures —
# does not touch measures/notes (run Annotate first if you want them
# in the picture).
# ─────────────────────────────────────────────────────────────────────

proc ::MaxStress::CaptureWindowImage {pageHandle winIdx setID csvRows outDir} {
    foreach handle {win clt model setc} { catch {${handle} ReleaseHandle} }
    $pageHandle GetWindowHandle win $winIdx
    win GetClientHandle clt
    clt GetModelHandle model [clt GetActiveModel]

    set _rid [ResolveSet $setID [ListSets]]
    if {$_rid eq ""} {
        puts "  skip win $winIdx: no selection set matching '$setID'"
        return
    }
    set setID $_rid
    if {[catch {model GetSelectionSetHandle setc $setID} err]} {
        puts "  skip win $winIdx: no selection set $setID ($err)"
        return
    }
    set setName [setc GetLabel]
    setc ReleaseHandle

    set nodeID ""
    foreach row $csvRows {
        lassign $row rWin rSetName rNodeID
        if {$rWin == $winIdx && $rSetName eq $setName} {
            set nodeID $rNodeID
            break
        }
    }
    if {$nodeID eq ""} {
        puts "  skip win $winIdx: no CSV row for set '$setName'"
        return
    }

    set safeName [regsub -all {[\\/:*?"<>|]} $setName "_"]
    set fname [file join $outDir "${safeName}_${winIdx}_${nodeID}.png"]
    if {[catch {clt CaptureImage $fname PNG 100} cerr]} {
        # clt CaptureImage is native/GPU and known to fail with "Failed to
        # allocate GPU memory" on some machines (RDP/virtual GPU, or many
        # captures back-to-back) — fall back to the session-level capture
        # family, which is server-side and doesn't touch the GPU.
        puts "  WARNING: clt CaptureImage failed win $winIdx ($cerr) — trying sess fallback"
        catch {$pageHandle SetActiveWindow $winIdx}
        set gw "" ; set gh ""
        catch {set gw [win GetGraphicsWidth]}
        catch {set gh [win GetGraphicsHeight]}
        if {$gw eq "" || $gh eq ""} { set gw 1920 ; set gh 1080 }
        if {[catch {sess CaptureActiveWindow PNG $fname pixel $gw $gh} cerr2]} {
            puts "  WARNING: sess CaptureActiveWindow also failed win $winIdx: $cerr2"
        } else {
            puts "  captured (fallback): $fname"
        }
    } else {
        puts "  captured: $fname"
    }
}

proc ::MaxStress::RunCapture {setID {outputDir ""}} {
    variable LIB_DIR
    if {$outputDir eq ""} { set outputDir $LIB_DIR }
    if {[string trim $setID] eq ""} {
        error "No selection set ID given."
    }
    set setID [lindex [split [string trim $setID]] 0]

    set csvFile "$outputDir/Stress_Summary.csv"
    if {![file exists $csvFile]} {
        error "Summary CSV not found: $csvFile — run Export first."
    }
    set f [open $csvFile r]
    set csvRows {}
    set lineNo 0
    while {[gets $f line] >= 0} {
        incr lineNo
        if {$lineNo == 1 || [string trim $line] eq ""} { continue }
        set fields [split $line ","]
        if {[llength $fields] < 6} { continue }
        lappend csvRows $fields
    }
    close $f

    CleanHandles
    OpenChain
    set numWindows [page GetNumberOfWindows]
    for {set wi 1} {$wi <= $numWindows} {incr wi} {
        if {[catch {CaptureWindowImage page $wi $setID $csvRows $outputDir} err]} {
            puts "!!!! Window $wi capture failed: $err"
        }
    }
    catch {hwi CloseStack}
    puts "--- Captured images for $numWindows window(s) to $outputDir ---"
    return $numWindows
}

# ─────────────────────────────────────────────────────────────────────
# ANNOTATE — per-window measure marker + summary note from the CSV
# ─────────────────────────────────────────────────────────────────────

proc ::MaxStress::annotateWindow {pageHandle winIdx setID csvRows pink meaSize noteSize} {

    foreach handle {win clt model rctrl con leg mea mtmp setc mfont note ntmp nfont} {
        catch {${handle} ReleaseHandle}
    }

    $pageHandle GetWindowHandle win $winIdx
    win GetClientHandle clt
    clt GetModelHandle model [clt GetActiveModel]
    model GetResultCtrlHandle rctrl

    puts ""
    puts "===== Window $winIdx ====="

    # Resolve set (ID or NAME) -> set name (CSV stores names, not IDs)
    set _rid [ResolveSet $setID [ListSets]]
    if {$_rid eq ""} {
        puts "  skip: this window's model has no selection set matching '$setID'"
        return
    }
    set setID $_rid
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

    # Jump to the ORIGINAL subcase whose label carries this row's angle —
    # the frame selector then shows the real step name (e.g.
    # "Step10_Combustion/Angle_1454.99deg:") for at-a-glance verification,
    # instead of an anonymous Derived_Case frame.
    set targetSC ""
    foreach sc [rctrl GetSubcaseList model] {
        set lbl [rctrl GetSubcaseLabel $sc]
        if {[string match "Derived_Case*" $lbl]} { continue }
        if {[AngleMatches [ExtractAngle $lbl] $angle]} {
            set targetSC $sc
            break
        }
    }
    if {$targetSC ne ""} {
        rctrl SetCurrentSubcase $targetSC
        # The export swept simulation 1 of each subcase (AppendSimulation
        # $sc 1) — jump to the same one; fall back to 0 for 1-sim subcases.
        if {[catch {rctrl SetCurrentSimulation 1}]} {
            catch {rctrl SetCurrentSimulation 0}
        }
        set simShow ""
        catch {set simShow [rctrl GetCurrentSimulation]}
        # Sync the animator — SetCurrentSimulation alone moves the data
        # pointer but the viewport keeps rendering the last-drawn frame.
        catch {
            $pageHandle GetAnimatorHandle _anim
            if {[catch {_anim SetCurrentStep $simShow}]} {
                _anim SetCurrentStep [_anim GetCurrentStep]
            }
            _anim ReleaseHandle
        }
        clt Draw
        puts "  frame set: '[rctrl GetSubcaseLabel $targetSC]' sim $simShow (animator synced)"
    } else {
        puts "  WARNING: no subcase label matches angle '$angle' — frame NOT changed, value shown may differ from CSV"
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
                # GUI-saved legend files only DEFINE ::post::LoadSettings
                # {legend_handle} — call it with our legend handle name.
                if {[llength [info procs ::post::LoadSettings]]} {
                    if {[catch {::post::LoadSettings leg} _lerr2]} {
                        puts "  WARNING: ::post::LoadSettings failed: $_lerr2"
                    } else {
                        puts "  legend TCL applied: [file tail $LEGEND_TCL] (::post::LoadSettings)"
                    }
                } else {
                    puts "  legend TCL sourced: [file tail $LEGEND_TCL]"
                }
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

    # Create the measure marker (toggleable via ::MaxStress::SHOW_MEASURE —
    # stale MaxStress_* markers above are always cleared first, so turning
    # this off and re-annotating also removes existing markers).
    variable SHOW_MEASURE
    if {$SHOW_MEASURE} {
        # ⚠️ Display-mode flags: everything except id (and scalar, if the
        # user opts in below) must be switched OFF explicitly — "scalar"
        # defaults ON for Nodal Contour measures.
        set mid [clt AddMeasure "Nodal Contour"]
        clt GetMeasureHandle mea $mid
        mea SetLabel "MaxStress_$setName"
        mea AddNode $nodeID
        foreach _flag {label project mag x_comp y_comp z_comp scalar system min max node_path distance prefix} {
            catch {mea SetDisplayMode $_flag false}
        }
        mea SetDisplayMode "id" true

        variable MEA_SHOW_VALUE
        if {$MEA_SHOW_VALUE} {
            mea SetDisplayMode "scalar" true
            variable MEA_PRECISION
            set _mp $MEA_PRECISION
            if {![string is integer -strict $_mp] || $_mp < 0 || $_mp > 10} { set _mp 3 }
            catch {mea SetNumericPrecision $_mp}
        }
        mea SetColor $pink

        if {![catch {mea GetFontHandle mfont}]} {
            catch {mfont SetSize $meaSize}      ;# SetSize points — console-confirmed
            catch {mfont ReleaseHandle}
        } else {
            puts "  WARNING: mea GetFontHandle failed — font size left at default"
        }

        mea SetVisibility true
    }

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
    # White filled style (the only style — merged with the old plain/
    # transparent variant since white is what's actually used). Big left
    # padding leaves a white area for the axis triad to render on; the
    # first line starts with "." because HV auto-trims leading whitespace
    # on line 1 (the dot anchors the indent), and every line is padded to
    # the same column so all 3 lines align.
    note SetText ".                      $line1\n                       Node ID: $nodeID\n                       MAX: $stress3 MPa"
    catch {note SetAlignment left}
    catch {note SetBorderThickness 1}
    catch {note SetTransparency false}
    catch {note SetBackgroundColor "255 255 255"}
    catch {note SetTextColor "0 0 0"}   ;# HV2022 defaults to white text
    catch {note SetScreenAnchor true}
    # Bottom-left placement (white pad sits under the triad). SetPosition's
    # coordinate system is undocumented — sniff it from GetPosition: values
    # <= 1 treated as normalized (origin assumed top-left), larger as
    # pixels sized from the window graphics area.
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
