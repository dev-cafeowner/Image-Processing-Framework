# Vivado snapshot

`current_project_snapshot/` contains the supplied `qrcode.xpr` and Block Design files for architecture/reference purposes.

The project files were modified after `qr_test_working_ver0.xsa` was exported. In addition, the original project references external `rtl/`, `ip_repo/`, `xdc/`, `sim/`, and `core/` paths that were not all stored directly under the `.xpr` directory.

For that reason:

- use `hardware/baseline/qr_test_working_ver0.xsa` as the exact verified hardware handoff;
- use `hardware/rtl/` as the recovered custom source set;
- do not treat the `.xpr` snapshot as a fully relocatable/reproducible project yet.

A later cleanup commit should add a Tcl-based project/IP regeneration flow using the recovered source tree.
