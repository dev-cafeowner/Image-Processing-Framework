# Vitis software baseline

`Qr_barcode_working_ver0_app/src/` is the selected UI-overlay-before baseline used for the initial repository import.

The Vitis workspace generated platform/BSP/build/IDE directories are intentionally not committed. Recreate the platform from:

`hardware/baseline/qr_test_working_ver0.xsa`

Then import/build the application source with Vitis 2024.2.

`tools/` contains host-side utilities recovered from the application directory and used during camera/image bring-up. Generated captures are excluded.
