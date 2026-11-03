# Offline build only. Never opens the programming cable or writes any device.
set base [file dirname [file normalize [info script]]]
if {[catch {
    cd $base/fpga/build_src/td_project/lab_ex5_i2s_v1.0_Runs/syn_1
    source settings.cfg
    set synWildParams {gate pack_effort high}
    source C:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/doc/scripts/DefaultFlow.tcl
    cd $base/fpga/build_src/td_project/lab_ex5_i2s_v1.0_Runs/phy_1
    # TD treats .tcl files as IP scripts; generate an ordinary SDC copy for
    # these top-level constraints and import it explicitly before placement.
    file copy -force $base/bgm_cdc.tcl $base/bgm_cdc_generated.sdc
    import_device eagle_s20.db -package EG4S20BG256
    open_project lab_ex5_i2s_v1.0.prj -noanalyze
    import_db ../syn_1/lab_ex5_i2s_v1.0_gate.db
    read_adc ../../../user_source/constraints_source/pin.adc
    read_sdc $base/bgm_cdc_generated.sdc
    set_param place hfn_opt_effort low
    set_param place seed 8
    commit_param -step place
    place
    export_db lab_ex5_i2s_v1.0_place.db
    commit_param -step route
    route
    fix_hold
    fix_hold
    report_qor -step route -file route.qor
    report_area -io_info -file ${prj_name}_phy.area
    update_timing -mode final
    report_timing_status -file ${prj_name}_phy.ts
    report_timing_summary -file final_timing.rpt
    report_timing_exception -file final_exceptions.rpt
    export_db ${prj_name}_pr.db
    commit_param -step bitgen
    bitgen -bit ${prj_name}.bit
} detail]} {
    puts stderr "BGM_BUILD_FAILED: $detail"
    exit 1
}
exit 0
