# hvtools_menu.tcl — register "HV Tools Panel" into the HyperWorks menu bar
# (Applications > Tools, next to HvTrans / HwLogViewer).
#
# Console-verified recipe (HV14): the HyperWorks menu bar is plain Tk.
# The hw-side menu object named "Tools" (type Menu) stores its live Tk
# widget path in ExternalName (e.g. .mainPulldowns.applications94.tools101)
# — items added to that Tk menu with `add command` appear IMMEDIATELY.
# (The hw-side InsertItem/CreateAppendMenu route builds objects but the GUI
# never repaints them, so pure Tk is the way.)
#
# Usage:
#   source <path>/hvtools_menu.tcl          ;# once per session
#   hw.exe <model> -tcl hvtools_menu.tcl    ;# auto-register at startup
#                                            (retries until menus exist)
# Idempotent — safe to source repeatedly. Opens HVTools_Panel.tcl from the
# SAME folder as this script.

namespace eval ::HVToolsMenu {
    variable PANEL [file join [file dirname [file normalize [info script]]] HVTools_Panel.tcl]
    variable LABEL "HV Tools Panel"
    variable TRIES 0
}

# Menu-click target: source the combined panel (it builds itself on source)
proc ::HVToolsMenu::Open {} {
    variable PANEL
    if {![file exists $PANEL]} {
        catch {tk_messageBox -icon error -title "HV Tools" \
            -message "Panel file not found:\n$PANEL"}
        return
    }
    uplevel #0 [list source $PANEL]
}

# Fallback discovery: walk the whole Tk tree for the menu that holds the
# known Applications>Tools entries.
proc ::HVToolsMenu::ScanTk {w} {
    foreach c [winfo children $w] {
        if {[winfo class $c] eq "Menu"} {
            set n ""
            catch {set n [$c index end]}
            if {$n ne "" && $n ne "none"} {
                for {set i 0} {$i <= $n} {incr i} {
                    set lb ""
                    catch {set lb [$c entrycget $i -label]}
                    if {$lb eq "HwLogViewer" || $lb eq "HvTrans"} {
                        return $c
                    }
                }
            }
        }
        set r [ScanTk $c]
        if {$r ne ""} { return $r }
    }
    return ""
}

# Primary discovery: hw menu controller -> item named "Tools" of type Menu
# -> ExternalName = live Tk widget path. No hardcoded widget numbers.
proc ::HVToolsMenu::FindToolsMenu {} {
    set found ""
    catch {
        catch {_hvtm_sess ReleaseHandle}
        catch {_hvtm_mc ReleaseHandle}
        hwi GetSessionHandle _hvtm_sess
        _hvtm_sess GetMenuControllerHandle _hvtm_mc
        foreach id [_hvtm_mc GetItemList {}] {
            if {[catch {_hvtm_mc GetItemHandle _hvtm_it $id}]} { continue }
            set nm "" ; set ty "" ; set ext ""
            catch {set nm [_hvtm_it GetItemName]}
            catch {set ty [_hvtm_it GetItemType]}
            if {$nm eq "Tools" && $ty eq "Menu"} {
                catch {set ext [_hvtm_it GetExternalName]}
            }
            catch {_hvtm_it ReleaseHandle}
            if {$ext ne ""} {
                set found $ext
                break
            }
        }
    }
    catch {_hvtm_mc ReleaseHandle}
    catch {_hvtm_sess ReleaseHandle}

    if {$found ne "" && [winfo exists $found]} {
        return $found
    }
    return [ScanTk .]
}

proc ::HVToolsMenu::Register {} {
    variable LABEL
    variable TRIES

    set m ""
    catch {set m [FindToolsMenu]}
    if {$m eq ""} {
        # Menus may not exist yet during startup (-tcl runs early) — retry
        incr TRIES
        if {$TRIES <= 15} {
            after 2000 ::HVToolsMenu::Register
            return
        }
        puts "HVToolsMenu: Tools menu not found after $TRIES tries — source HVTools_Panel.tcl manually."
        return
    }

    # Idempotent: drop any earlier copies of our entry
    set n [$m index end]
    for {set i $n} {$i >= 0} {incr i -1} {
        set lb ""
        catch {set lb [$m entrycget $i -label]}
        if {$lb eq $LABEL} {
            $m delete $i
        }
    }
    # Separator only if the current last entry isn't one already
    if {[$m type [$m index end]] ne "separator"} {
        $m add separator
    }
    $m add command -label $LABEL -command ::HVToolsMenu::Open
    puts "HVToolsMenu: '$LABEL' added to Applications > Tools ($m)"
}

::HVToolsMenu::Register
