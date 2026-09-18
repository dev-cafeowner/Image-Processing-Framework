@{
    profiles = @(
        @{id='stage4_start'; label='Stage4 30fps (start reference)'; group='reference'; family='stage4'; elf='Vitis_video30_stage4/drive1x/Qr_barcode_working_ver0_app.elf'}
        @{id='original'; label='Original Vitis_run'; group='main'; family='software'; elf='Vitis_run/Qr_barcode_working_ver0_app/build/Qr_barcode_working_ver0_app.elf'}
        @{id='baseline_o0'; label='Original O0 + instrumentation'; group='intermediate'; family='software'; elf='Vitis_sw_baseline/build/Qr_barcode_working_ver0_app.elf'}
        @{id='sw_o2_first'; label='SW O2 first optimization'; group='intermediate'; family='software'; elf='Vitis_sw_stage1/stage1.elf'}
        @{id='sw_continuous'; label='SW continuous preview intermediate'; group='intermediate'; family='software'; elf='Vitis_sw_stage2/continuous.elf'}
        @{id='sw_o0_control'; label='SW O0 intermediate control'; group='intermediate'; family='software'; elf='Vitis_sw_perf_O0/build/Qr_barcode_working_ver0_app.elf'}
        @{id='sw_final'; label='SW final O2 / early ACK'; group='main'; family='software'; elf='Vitis_sw_perf/build/Qr_barcode_working_ver0_app.elf'}
        @{id='hw_slow_first'; label='PL+PS initial CLKRC=1'; group='intermediate'; family='hardware'; elf='Vitis_hw_perf_slow/build/Qr_barcode_working_ver0_app.elf'}
        @{id='hw_fast'; label='PL+PS CLKRC=0 fast experiment'; group='intermediate'; family='hardware'; elf='Vitis_hw_perf_fast/build/Qr_barcode_working_ver0_app.elf'}
        @{id='hw_final'; label='PL+PS stable CLKRC=1'; group='main'; family='hardware'; elf='Vitis_hw_perf/build/Qr_barcode_working_ver0_app.elf'}
        @{id='stage1_legacy'; label='Stage1 legacy preview / per-frame logs'; group='intermediate'; family='hardware'; elf='Vitis_video30_stage1/legacy/Qr_barcode_working_ver0_app.elf'}
        @{id='stage1_legacy_verified'; label='Stage1 verified scalar legacy control'; group='intermediate'; family='hardware'; elf='Vitis_video30_stage1/legacy_verified/Qr_barcode_working_ver0_app.elf'}
        @{id='stage1'; label='Stage1 NEON preview / window logs'; group='main'; family='hardware'; elf='Vitis_video30_stage1/build/Qr_barcode_working_ver0_app.elf'}
        @{id='stage2'; label='Stage2 autonomous PL preview'; group='main'; family='stage2'; elf='Vitis_video30_stage2/build/Qr_barcode_working_ver0_app.elf'}
        @{id='stage3_initial30'; label='Stage3 initial rejected 30fps'; group='intermediate'; family='stage3'; elf='Vitis_video30_stage3/rejected_30fps_initial.elf'}
        @{id='stage3_half'; label='Stage3 initial 15fps'; group='intermediate'; family='stage3'; elf='Vitis_video30_stage3/half/Qr_barcode_working_ver0_app.elf'}
        @{id='stage3_1x30'; label='Stage3 30fps sensor drive 1x'; group='intermediate'; family='stage3'; elf='Vitis_video30_stage3/drive1x/Qr_barcode_working_ver0_app.elf'}
        @{id='stage3_3x30'; label='Stage3 30fps sensor drive 3x'; group='intermediate'; family='stage3'; elf='Vitis_video30_stage3/drive3x/Qr_barcode_working_ver0_app.elf'}
        @{id='stage3_retest30'; label='Stage3 30fps 2x / preflight guards'; group='intermediate'; family='stage3'; elf='Vitis_video30_stage3/retest30_20260917/Qr_barcode_working_ver0_app.elf'}
        @{id='stage3'; label='Stage3 stable 15fps'; group='main'; family='stage3'; elf='Vitis_video30_stage3/build/Qr_barcode_working_ver0_app.elf'}
        @{id='stage4_2x'; label='Stage4 30fps sensor drive 2x'; group='intermediate'; family='stage4'; elf='Vitis_video30_stage4/build/Qr_barcode_working_ver0_app.elf'}
        @{id='stage4_slowclk'; label='Stage4 30fps XCLK DRIVE4/SLOW'; group='intermediate'; family='stage4'; elf='Vitis_video30_stage4/drive1x/Qr_barcode_working_ver0_app.elf'; bit='Vivado/qr_video30_stage4/qr_video30_stage4_xclk_slow4.bit'}
        @{id='stage4'; label='Stage4 selected 30fps (end reference)'; group='main'; family='stage4'; elf='Vitis_video30_stage4/drive1x/Qr_barcode_working_ver0_app.elf'}
    )
    families = @{
        software=@{runner='tools/run_software_perf.tcl';bit='Vivado/qr_probe/qr_camera_fixed.bit';xsa='Vivado/qr_probe/qr_camera_fixed.xsa'}
        hardware=@{runner='tools/run_hardware_perf.tcl';bit='Vivado/qr_perf/qr_perf.bit';xsa='Vivado/qr_perf/qr_perf.xsa'}
        stage2=@{runner='tools/run_video30_stage2.tcl';bit='Vivado/qr_video30_stage2/qr_video30_stage2.bit';xsa='Vivado/qr_video30_stage2/qr_video30_stage2.xsa'}
        stage3=@{runner='tools/run_video30_stage3.tcl';bit='Vivado/qr_video30_stage3/qr_video30_stage3.bit';xsa='Vivado/qr_video30_stage3/qr_video30_stage3.xsa'}
        stage4=@{runner='tools/run_video30_stage4.tcl';bit='Vivado/qr_video30_stage4/qr_video30_stage4.bit';xsa='Vivado/qr_video30_stage4/qr_video30_stage4.xsa'}
    }
    exclusions='Colorbar / blank injection are not real QR scenes. FSBLs are boot components. legacy_compile and stage4_compat15 are compile-regression artifacts, not separate selected performance versions. Rejected RGB passthrough hardware was never a validated pipeline and is not deployed.'
}
