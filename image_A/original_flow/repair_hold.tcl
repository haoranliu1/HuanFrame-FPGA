# Offline timing repair from the backed-up routed database.
set base [file dirname [file normalize [info script]]]
if {[catch {
    cd $base/fpga/build_src/td_project/lab_ex5_i2s_v1.0_Runs/phy_1
    import_device eagle_s20.db -package EG4S20BG256
    open_project lab_ex5_i2s_v1.0.prj -noanalyze
    import_db lab_ex5_i2s_v1.0_pr.db
    read_adc ../../../user_source/constraints_source/pin.adc
    read_sdc $base/bgm_cdc_generated.sdc
    fix_hold
    report_qor -step route -file release_hold2_route.qor
    report_area -io_info -file release_hold2_phy.area
    update_timing -mode final
    report_timing_status -file release_hold2_phy.ts
    report_timing_summary -file release_hold2_timing.rpt
    export_db release_hold2_pr.db
    commit_param -step bitgen
    bitgen -bit release_hold2.bit
} detail]} {
    puts stderr "RELEASE_HOLD_REPAIR_FAILED: $detail"
    exit 1
}
exit 0
