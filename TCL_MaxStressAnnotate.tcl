puts "---Max Stress Annotation---"
puts "########  BY NGUYEN TAN LOC  ########"
puts ""

# Standalone companion to TCL_StressExport.tcl.
# Reads Stress_Summary.csv (produced by the export script, same folder),
# asks for ONE selection-set ID, then for every window on the page:
#   - jumps to the derived-case frame where that set's max stress occurred
#   - creates a "Nodal Contour" measure on the max-stress node
#   - shows node ID + contour value, font size 15, pink
# Measures are per-window in HyperView, so one measure is created in each
# window from that window's own CSV row.

#### CLEAN UP HANDLES ####
foreach handle {sess proj object page win clt model rctrl sub con leg iso math query vw se sys mea mtmp setc mfont note ntmp nfont} {
    catch {${handle} ReleaseHandle}
}
catch {hwi CloseStack}

set outputDir [file dirname [file normalize [info script]]]
set csvFile "$outputDir/Stress_Summary.csv"

if {![file exists $csvFile]} {
    error "Summary CSV not found: $csvFile — run TCL_StressExport.tcl first."
}

#### READ SUMMARY CSV ####
# Columns: WindowID,SetName,MaxNodeID,MaxStressValue_MPa,SimulationID,CrankAngle_deg,SimulationLabel
set f [open $csvFile r]
set csvRows {}
set lineNo 0
while {[gets $f line] >= 0} {
    incr lineNo
    if {$lineNo == 1} { continue }                 ;# header
    if {[string trim $line] eq ""} { continue }
    set fields [split $line ","]
    if {[llength $fields] < 6} { continue }
    lappend csvRows $fields
}
close $f
puts "--- Loaded [llength $csvRows] row(s) from $csvFile ---"

#### TOP-LEVEL HANDLES ####
hwi OpenStack
hwi GetSessionHandle sess
sess GetProjectHandle proj
proj GetPageHandle page [proj GetActivePage]

#### USER INPUT — one set ID per run ####
puts -nonewline "=> Enter ONE selection set ID to annotate: "
update idletasks
gets stdin userInput
set setID [lindex [split [string trim $userInput]] 0]
if {$setID eq ""} {
    error "No selection set ID entered."
}

set PINK  "252 62 255"    ;# read back from the GUI-made pink measure (GetColor)
set FSIZE 15

proc annotateWindow {pageHandle winIdx setID csvRows pink fsize} {

    foreach handle {win clt model rctrl mea mtmp setc mfont note ntmp nfont} {
        catch {${handle} ReleaseHandle}
    }

    # GetWindowHandle takes an INDEX 1..N (confirmed live), not an ID
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
            # SimulationLabel = 7th column (may have been split if it ever
            # contains commas — rejoin), quoted on write; keep the part
            # before the first colon as a compact frame name.
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

    # Jump to the frame the max was measured on — SimulationID indexes
    # into this window's Derived_Case_Win<idx> from the export script.
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

    # Remove annotations from a previous run of this script (re-runnable)
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

    # Create the annotation measure.
    # ⚠️ All display-mode flags default to OFF for TCL-created measures
    # (confirmed live) — must enable explicitly or nothing renders.
    set mid [clt AddMeasure "Nodal Contour"]
    clt GetMeasureHandle mea $mid
    mea SetLabel "MaxStress_$setName"
    mea AddNode $nodeID
    mea SetDisplayMode "id"     true
    mea SetDisplayMode "scalar" true      ;# contour value at the node
    mea SetColor $pink

    # Font size — the size method name on the font handle is not yet
    # console-confirmed; try the two likely names, else print the real
    # method list so it can be fixed.
    if {![catch {mea GetFontHandle mfont}]} {
        if {[catch {mfont SetSize $fsize}]} {
            if {[catch {mfont SetHeight $fsize}]} {
                puts "  WARNING: font size method unknown — font methods: [mfont ListMethods]"
            }
        }
        catch {mfont ReleaseHandle}
    } else {
        puts "  WARNING: mea GetFontHandle failed — font size left at default"
    }

    mea SetVisibility true

    # ── Summary note (frame name + node ID + max value) ──────────────
    # A separate note per window; the built-in "Model Info" note is left
    # untouched (it uses auto-updating templex fields).
    # Remove this script's note from a previous run first.
    set staleNotes {}
    catch {
        foreach nid [clt GetNoteList] {
            clt GetNoteHandle ntmp $nid
            set nname ""
            catch {set nname [ntmp GetName]}
            if {$nname eq ""} { catch {set nname [ntmp GetLabel]} }
            if {[string match "MaxStress_*" $nname]} {
                lappend staleNotes $nid
            }
            ntmp ReleaseHandle
        }
    }
    foreach nid $staleNotes {
        catch {clt RemoveNote $nid}
    }

    set nid [clt AddNote 0]
    clt GetNoteHandle note $nid            ;# handle NAME first, then id
    catch {note SetName  "MaxStress_$setName"}
    catch {note SetLabel "MaxStress_$setName"}
    note SetText "Frame: $frameName\nNode ID: $nodeID\nMax Stress: $stressVal MPa"
    catch {note SetScreenAnchor true}       ;# match GUI "Anchor to screen"
    if {![catch {note GetFontHandle nfont}]} {
        catch {nfont SetSize $fsize}
        catch {nfont ReleaseHandle}
    }
    note SetVisibility true

    clt Draw
    puts "  measure 'MaxStress_$setName' created (id $mid), note id $nid"
}

set numWindows [page GetNumberOfWindows]
puts "--- Found $numWindows window(s) on this page ---"

for {set winIdx 1} {$winIdx <= $numWindows} {incr winIdx} {
    if {[catch {annotateWindow page $winIdx $setID $csvRows $PINK $FSIZE} err]} {
        puts ""
        puts "!!!! Window $winIdx failed, skipping it: $err"
    }
}

puts ""
puts "-------------------------------------"
puts "################  Annotation done.  ################"
hwi CloseStack
