puts "---Max Stress Evaluation---"
puts "########  BY NGUYEN TAN LOC  ########"
puts ""

# Console wrapper — all logic lives in maxstress_lib.tcl.
# For the button-panel version, source MaxStress_Panel.tcl instead.
source [file join [file dirname [file normalize [info script]]] maxstress_lib.tcl]

puts -nonewline "=> Enter selection set IDs (space-separated): "
update idletasks
gets stdin userInput
set selectionSets [split [string trim $userInput]]

::MaxStress::RunExport $selectionSets

puts "################  All windows processed.  ################"
