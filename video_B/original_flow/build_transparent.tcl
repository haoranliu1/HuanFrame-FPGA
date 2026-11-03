# Isolated source revision. Preserve original clocks, pins and constraints.
set base [file dirname [file normalize [info script]]]
if {$argc != 1 || [lsearch -exact {image video} [lindex $argv 0]] < 0} {
    puts stderr "Expected image or video profile"
    exit 1
}
set profile [lindex $argv 0]
if {[catch {
    cd $base/$profile/build_src/td_project/lab_ex5_i2s_v1.0_Runs/syn_1
    source settings.cfg
    source C:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/doc/scripts/DefaultFlow.tcl
    cd $base/$profile/build_src/td_project/lab_ex5_i2s_v1.0_Runs/phy_1
    source settings.cfg
    if {$profile eq "image"} {
        set phyWildParams {place seed 8}
    } else {
        set phyWildParams {place seed 9}
    }
    source C:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/doc/scripts/DefaultFlow.tcl
    fix_hold
    report_qor -step route -file route.qor
    report_area -io_info -file ${prj_name}_phy.area
    update_timing -mode final
    report_timing_status -file ${prj_name}_phy.ts
    report_timing_summary -file final_timing.rpt
    export_db ${prj_name}_pr.db
    commit_param -step bitgen
    bitgen -bit ${prj_name}.bit
} detail]} {
    puts stderr "TRANSPARENT_BUILD_FAILED: $detail"
    exit 1
}
exit 0
