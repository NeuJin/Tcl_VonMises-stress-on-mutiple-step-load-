puts "---Max Stress Evaluation---"
puts "########  BY NGUYEN TAN LOC  ########"
puts ""
puts " "

#### CLEAN UP HANDLES ####
foreach handle {sess proj object page win clt model rctrl sub con leg iso math query vw se sys} {
    catch {${handle} ReleaseHandle}
}
catch {hwi CloseStack}

set outputDir [file dirname [file normalize [info script]]]

### DERIVED LOAD CASE CREATE ###
hwi OpenStack
hwi GetSessionHandle sess
sess GetProjectHandle proj
proj GetPageHandle page [proj GetActivePage]
page GetWindowHandle win [page GetActiveWindow]
win GetClientHandle clt
clt GetModelHandle model [clt GetActiveModel]

model GetResultCtrlHandle rctrl
set subcases [rctrl GetSubcaseList model]
set numSubcases [llength $subcases]
set derivedSubcaseID [expr {$numSubcases + 1}]

rctrl AddSubcase Derived_Case
rctrl GetSubcaseHandle sub $derivedSubcaseID

for {set sc 0} {$sc < $derivedSubcaseID} {incr sc} {
    sub AppendSimulation $sc 1
}

puts "--- Derived Case created! ---"

### USER INPUT ###
puts -nonewline "=> Enter selection set IDs (space-separated): "
update idletasks
gets stdin userInput
set selectionSets [split $userInput]

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
set numFrames [expr {$derivedSubcaseID - 3}]
puts ""
puts "--- Derived Case created! ---"
puts "-------- Query Info ---------"
set subLabel [rctrl GetSubcaseLabel $derivedSubcaseID]
puts "Subcase name:         $subLabel"
puts "Total frames in derived subcase:  $numFrames\n"

        query SetDataSourceProperty result "Model ID" 1
        query SetDataSourceProperty result "Result Type" "S-Stress components"
        query SetDataSourceProperty result "Load Case" Derived_Case
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
#puts "---"

#### MAX STRESS TRACKING ####
array set maxStress {}
array set maxNodeID {}
array set maxSimLabel {}

package require Tk
toplevel .status
wm title .status "Tracking Crank Angles"
label .status.l -text "Processing frames "
ttk::progressbar .status.p -length 320 -mode determinate -maximum $numFrames -value 0
pack .status.l -pady 5
pack .status.p -padx 10 -pady 8

foreach setID $selectionSets {
    set maxStress($setID) -1e30
    set maxNodeID($setID) ""
    set maxSimLabel($setID) ""
}

set derivedSimList [rctrl GetDerivedSimulationList $derivedSubcaseID]

for {set frameIdx 1} {$frameIdx <= $numFrames} {incr frameIdx} {

    #puts "Processing frame $frameIdx..."
    set pct [expr {int(100.0*$frameIdx/$numFrames)}]
    .status.l configure -text "Operating Frame $frameIdx $pct%"
    .status.p configure -value $frameIdx
    update
    after 40

    set frameIdx1 [expr {$frameIdx - 1}]
    # Set current simulation/frame first
    rctrl SetCurrentSubcase $derivedSubcaseID
    rctrl SetCurrentSimulation $frameIdx1

    # Immediately get simulation label for this frame
    set simLabel [lindex $derivedSimList [expr {$frameIdx - 1}]]
    #puts "Frame $frameIdx corresponds to simulation label: $simLabel"

    # Prepare to collect data for all sets for this frame
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
            #puts " $dataList "

            # Update max stress immediately with current simLabel
            set nodeID [lindex $data 0]
            set stressVal [lindex $data 1]
            #puts " ID: $nodeID --- $stressVal "
            if {$stressVal > $maxStress($setID)} {
                #puts "New max for set $setID: $stressVal at node $nodeID (simLabel: $simLabel)"
                set maxStress($setID) $stressVal
                set maxNodeID($setID) $nodeID
                set maxSimLabel($setID) $simLabel
            }
        }

        iter ReleaseHandle

        set frameData($setID) $dataList
        if {[llength $dataList] > $maxNodes} {
            set maxNodes [llength $dataList]
        }
    }

    # Write CSV file for this frame
    set frameFileName [format "%s/Stress_Frame%03d.csv" $outputDir $frameIdx]
    set f [open $frameFileName w+]

    # Write header
    set header "Row"
    foreach setID $selectionSets {
        model GetSelectionSetHandle setz $setID
        set setName [setz GetLabel]
        setz ReleaseHandle
        append header ",${setName}_NodeID,${setName}_Stress(MPa)"
    }
    puts $f $header

    # Write data rows
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
    #puts "Exported frame $frameIdx data to $frameFileName"
    #puts " --- "
}

destroy .status

# Write summary CSV
set summaryFileName [format "%s/Stress_Summary.csv" $outputDir]
set f [open $summaryFileName w+]
puts $f "SetName,MaxNodeID,MaxStressValue,SimulationLabel"
puts $f " "
puts $f " "
puts $f "------- Max Stress Summary --------"
puts $f " "
puts $f "SetName   NodeID    StressValue   Angle "
foreach setID $selectionSets {
    model GetSelectionSetHandle setc $setID
    set setName [setc GetLabel]
    setc ReleaseHandle
    set simLabel $maxSimLabel($setID)

    # Find position of first underscore
    set pos0 [string first "_" $simLabel]

    # Find position of second underscore
    set pos1 [string first "_" $simLabel [expr {$pos0 + 1}]]

    # Find position of first colon after underscore
    set pos2 [string first ":" $simLabel]

    if {$pos1 >= 0 && $pos2 > $pos1} {
        # Extract substring between pos1+1 and pos2-1
        set simLabels [string range $simLabel [expr {$pos1 + 1}] [expr {$pos2 - 1}]]
        puts $f "$setName,$maxNodeID($setID),$maxStress($setID),\"$simLabels\""
        puts "$setName,$maxNodeID($setID),$maxStress($setID),\"$simLabels\""
    }
}
close $f

puts "-------------------------------------"
puts "Exported all frames data to $outputDir"
puts "-------------------------------------"
puts "################  All frames processed.  ################"
hwi CloseStack
