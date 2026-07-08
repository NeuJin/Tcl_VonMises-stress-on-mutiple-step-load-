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
set winIDList [page GetWindowIDList]
set numWindows [llength $winIDList]
puts ""
puts "--- Found $numWindows window(s) on this page: $winIDList ---"

# Collected across ALL windows, written once to a single summary CSV at the end.
# Each row: {winID setName maxNodeID maxStressValue maxSimID crankAngle simLabel}
set summaryRows {}

proc processWindow {pageHandle winID selectionSets outputDir summaryRowsVar} {
    upvar 1 $summaryRowsVar summaryRows

    # Release any leaf handles left over from a previous window's processing
    foreach handle {win clt model rctrl sub con leg iso math query vw se sys iter setc setz} {
        catch {${handle} ReleaseHandle}
    }

    $pageHandle GetWindowHandle win $winID
    win GetClientHandle clt
    clt GetModelHandle model [clt GetActiveModel]

    set winOutDir "$outputDir/Win${winID}"
    file mkdir $winOutDir

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
    # doesn't exist, same trap as window IDs being 4 6 8... not 1 2 3...).
    foreach sc $subcases {
        # Skip subcases created by an EARLIER window's own Derived_Case —
        # if two windows share the same underlying model, that subcase now
        # shows up in this window's list too, and HyperView rejects deriving
        # a new case from an already-derived one.
        set scLabel [rctrl GetSubcaseLabel $sc]
        if {[string match "Derived_Case*" $scLabel]} {
            continue
        }
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

        array set frameData {}
        set maxNodes 0

        foreach setID $selectionSets {
            model GetSelectionSetHandle setc $setID
            set setName [setc GetLabel]
            setc ReleaseHandle

            query SetDataSourceProperty result "Simulation Step" $frameIdx1
            query SetSelectionSet $setID
            query SetQuery "node.id contour.value"
            query GetQuery

            query GetIteratorHandle iter
            set dataList {}

            for {iter First} {[iter Valid]} {iter Next} {
                set data [iter GetDataList]
                lappend dataList $data

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

            set frameData($setID) $dataList
            if {[llength $dataList] > $maxNodes} {
                set maxNodes [llength $dataList]
            }
        }

        # Write CSV file for this frame
        set frameFileName [format "%s/Stress_Frame%03d.csv" $winOutDir $frameIdx]
        set f [open $frameFileName w+]

        set header "Row"
        foreach setID $selectionSets {
            model GetSelectionSetHandle setz $setID
            set setName [setz GetLabel]
            setz ReleaseHandle
            append header ",${setName}_NodeID,${setName}_Stress(MPa)"
        }
        puts $f $header

        for {set i 0} {$i < $maxNodes} {incr i} {
            set line "$i"
            foreach setID $selectionSets {
                set dataList $frameData($setID)
                if {$i < [llength $dataList]} {
                    set nodeID [lindex [lindex $dataList $i] 0]
                    set value [lindex [lindex $dataList $i] 1]
                    set formattedValue [format "%.8f" $value]
                    append line ",$nodeID,$formattedValue"
                } else {
                    append line ",,"
                }
            }
            puts $f $line
        }

        close $f
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
    puts "--- Window $winID done. Per-frame CSVs: $winOutDir ---"
}

foreach winID $winIDList {
    if {[catch {processWindow page $winID $selectionSets $outputDir summaryRows} err]} {
        puts ""
        puts "!!!! Window $winID failed, skipping it: $err"
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
