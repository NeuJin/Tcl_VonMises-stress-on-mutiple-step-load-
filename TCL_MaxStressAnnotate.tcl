puts "---Max Stress Annotation---"
puts "########  BY NGUYEN TAN LOC  ########"
puts ""

# Console wrapper — all logic lives in maxstress_lib.tcl.
# For the button-panel version, source MaxStress_Panel.tcl instead.
source [file join [file dirname [file normalize [info script]]] maxstress_lib.tcl]

puts -nonewline "=> Enter ONE selection set ID to annotate: "
update idletasks
gets stdin userInput

::MaxStress::RunAnnotate $userInput
