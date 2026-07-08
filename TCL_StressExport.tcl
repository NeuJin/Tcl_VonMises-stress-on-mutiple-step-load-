puts "---Max Stress Evaluation---"
puts "########  BY NGUYEN TAN LOC  ########"
puts ""
puts " "

#### CLEAN UP HANDLES ####
foreach handle {sess proj object page win clt model rctrl sub con leg iso math query vw se sys iter setc setz} {
    catch {${handle} ReleaseHandle}
}
catch {hwi CloseStack}

set outputDir [file dirname [file normalize [info script]]]

### TOP-LEVEL HANDLES (persist across all windows) ###
hwi OpenStack
hwi GetSessionHandle sess
sess GetProjectHandle proj
proj GetPageHandle page [proj GetActivePage]

### USER INPUT (entered once, applied to every window) ###
puts -nonewline "=> Enter selection set IDs (space-separated): "
update idletasks
gets stdin userInput
set selectionSets [split $userInput]

### ENUMERATE ALL WINDOWS ON THE PAGE ###
# GetWindowHandle takes a window INDEX (1..N), NOT an ID from
# GetWindowIDList — live run proved it: IDs were 4 6 8 10 12 14 16 18,
# and only 4/6/8 "worked" (they happened to be valid indexes, actually
# grabbing the 4th/6th/8th window) while 10+ failed with
# 'invalid command name "win"'.
set numWindows [page GetNumberOfWindows]
puts ""
puts "--- Found $numWindows window(s) on this page ---"

# Subcases whose label matches any of these patterns are excluded from the
# derived case: Derived_Case* (can't derive from an already-derived case)
# and *Bolt* (bolt-tightening steps — not crank-angle frames; the original
# script's "-3" arithmetic existed to exclude these).
set skipSubcasePatterns {Derived_Case* *Bolt*}

# Collected across ALL windows, written once to a single summary CSV at the end.
# Each row: {winID setName maxNodeID maxStressValue maxSimID crankAngle simLabel}
set summaryRows {}

proc processWindow {pageHandle winID selectionSets skipPatterns summaryRowsVar} {
    upvar 1 $summaryRowsVar summaryRows

    # Release any leaf handles left over from a previous window's processing
    foreach handle {win clt model rctrl sub con leg iso math query vw se sys iter setc setz} {
        catch {${handle} ReleaseHandle}
    }

    $pageHandle GetWindowHandle win $winID
    win GetClientHandle clt
    clt GetModelHandle model [clt GetActiveModel]

    puts ""
    puts "===================================================="
    puts " Window $winID"
    puts "===================================================="

    ### DERIVED LOAD CASE CREATE ###
    # Name is unique per window so re-running/multiple windows on the same
    # model never collide with an existing "Derived_Case".
    model GetResultCtrlHandle rctrl
    set subcases [rctrl GetSubcaseList model]
    set numSubcases [llength $subcases]
    set derivedSubcaseID [expr {$numSubcases + 1}]
    set derivedCaseName "Derived_Case_Win${winID}"

    rctrl AddSubcase $derivedCaseName
    rctrl GetSubcaseHandle sub $derivedSubcaseID

    # Iterate the REAL subcase IDs from GetSubcaseList — IDs are not
    # guaranteed to start at 0 or be contiguous (live run showed "subcase 0"
    # doesn't exist, same trap as window IDs vs indexes).
    foreach sc $subcases {
        # Skip non-frame subcases: earlier windows' Derived_Case* (HyperView
        # rejects deriving from an already-derived case when windows share a
        # model) and bolt-tightening steps (*Bolt*) which aren't crank angles.
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

    #### INITIALIZE HANDLES ####
    rctrl GetContourCtrlHandle con
    con GetLegendHandle leg
    rctrl GetIsoValueCtrlHandle iso
    rctrl GetResultMathCtrlHandle math
    model GetQueryCtrlHandle query
    iso SetAverageMode Simple
    win GetViewControlHandle vw
    con GetSelectionSetHandle se
    rctrl GetSystemCtrlHandle sys

    #### SET DATA PROPERTIES ####
    con SetDataType {S-Stress components}
    con SetDataComponent Mises
    con SetAverageMode simple
    con SetCornerDataEnabled true
    con SetEnableState true
    con SetAvgAcrossPartsEnable enable
    leg SetNumericPrecision 8

    #### FRAME INFO ####
    # Count frames from what was ACTUALLY appended into the derived case,
    # not from derivedSubcaseID arithmetic — with shared models each window
    # adds one more Derived_Case_Win* to the subcase list, so the old
    # "derivedSubcaseID - 3" grew every window (16, 19, ... frames) and the
    # later windows would sweep past the real end of the data.
    set derivedSimList [rctrl GetDerivedSimulationList $derivedSubcaseID]
    set numFrames [llength $derivedSimList]
    set subLabel [rctrl GetSubcaseLabel $derivedSubcaseID]
    puts "Subcase name:                     $subLabel"
    puts "Total frames in derived subcase:  $numFrames"

    query SetDataSourceProperty result "Model ID" 1
    query SetDataSourceProperty result "Result Type" "S-Stress components"
    query SetDataSourceProperty result "Load Case" $derivedCaseName
    query SetDataSourceProperty result "Component" Mises
    query SetDataSourceProperty result corners true
    query SetDataSourceProperty result complex real
    query SetDataSourceProperty result complex_format real
    query SetDataSourceProperty result mutiline true
    query SetDataSourceProperty result dataformat csv
    query SetDataSourceProperty result datatype real
    query SetDataSourceProperty result layer all

    set ResultTYPE [query GetDataSourceProperty result "Result Type"]
    set ComponentTYPE [query GetDataSourceProperty result "Component"]
    set CornersTYPE [query GetDataSourceProperty result corners]
    set AveraMODE [con GetAverageMode]
    puts "Evaluation:      $ResultTYPE - $ComponentTYPE"
    puts "Use corners data:    $CornersTYPE"
    puts "Average mode:        $AveraMODE"

    #### MAX STRESS TRACKING ####
    # maxSimID = the 0-based simulation index (as passed to rctrl
    # SetCurrentSimulation) that produced the max value — kept separate from
    # maxSimLabel (the human-readable crank-angle string) so callers can jump
    # straight back to that frame programmatically without re-parsing text.
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

    # Fold this window's per-set results into the shared cross-window summary.
    foreach setID $selectionSets {
        model GetSelectionSetHandle setc $setID
        set setName [setc GetLabel]
        setc ReleaseHandle

        set simLabel $maxSimLabel($setID)

        # Crank angle is embedded in the label as "..._Angle_<value>deg..." —
        # extract the substring between the 2nd underscore and the next colon.
        # Falls back to "N/A" (instead of silently dropping the whole row,
        # which the original script did) if the label doesn't match.
        set angle "N/A"
        set pos0 [string first "_" $simLabel]
        set pos1 [string first "_" $simLabel [expr {$pos0 + 1}]]
        set pos2 [string first ":" $simLabel]
        if {$pos1 >= 0 && $pos2 > $pos1} {
            set angle [string range $simLabel [expr {$pos1 + 1}] [expr {$pos2 - 1}]]
        }

        set formattedMax [format "%.8f" $maxStress($setID)]
        lappend summaryRows [list $winID $setName $maxNodeID($setID) $formattedMax \
            $maxSimID($setID) $angle $simLabel]
    }

    win ReleaseHandle
    puts "--- Window $winID done ---"
}

for {set winIdx 1} {$winIdx <= $numWindows} {incr winIdx} {
    if {[catch {processWindow page $winIdx $selectionSets $skipSubcasePatterns summaryRows} err]} {
        puts ""
        puts "!!!! Window $winIdx failed, skipping it: $err"
        catch {destroy .status}
    }
}

#### WRITE ONE CLEAN SUMMARY CSV ACROSS ALL WINDOWS ####
# Pure CSV — single header row, one data row per (window, selection set).
# No decorative/blank lines mixed in, so it opens cleanly in Excel/pandas.
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
puts "################  All windows processed.  ################"
hwi CloseStack
