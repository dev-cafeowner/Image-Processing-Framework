# Baseline provenance

## PS baseline

Source archive: `qr_working_ver_vitis_baseline.tar.gz`

Selected application: `vitis/Qr_barcode_working_ver0_app`

Evidence in the selected source:

- `src/helloworld.c` includes `stage6_qr_runtime.h`.
- `main()` calls `stage6_qr_runtime_run()`.
- `src/UserConfig.cmake` includes `stage6_qr_runtime.c` in the application source list.
- The later `hdmi_ui.c/.h` files found at the application root were timestamped after the selected Stage 6 source and were not referenced by the application source/CMake configuration; they are therefore not included in this baseline import.

## Hardware baseline

Selected export: `qr_test_working_ver0.xsa`

SHA-256:

`5ae75524e74b10f46c604495ac7cdf64c7b952d2a4cc9c8adab6e5067348f2f7`

The same hash is present in:

- the supplied Vivado archive, and
- the Vitis platform associated with `Qr_barcode_working_ver0_app`.

This establishes the XSA as the exact hardware handoff used by the selected software baseline.

## RTL source selection

The supplied Vivado archive references custom source trees outside its top-level `.srcs` directory. Copies of those custom-IP sources were recovered from `qrcode.ip_user_files/.../ipshared/`:

- camera / OV7670 source snapshot
- configurable vision front-end source snapshot
- Run-Length / Vertical Cross-Check source snapshot
- Sparse CCL / QRP1 / runtime CSR source snapshot

These source snapshots have modification timestamps before the verified XSA export. They are preserved as the closest available RTL source set associated with the hardware project.

The Vivado `.xpr` and `.bd` supplied in the archive were modified after the verified XSA export. They are therefore retained only in `hardware/vivado/current_project_snapshot/` and are not represented as an exact baseline project reconstruction.
