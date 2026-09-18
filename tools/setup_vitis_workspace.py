"""Create and build the verified Zybo Z7-20 Vitis workspace.

Run with the Vitis 2024.2 launcher, for example:
  C:\\Xilinx\\Vitis\\2024.2\\bin\\vitis.bat -s tools\\setup_vitis_workspace.py

The script deliberately creates all generated files in ./Vitis, leaving the
tracked hardware handoff and application sources untouched.
"""

from pathlib import Path
import os
import shutil

import vitis


ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = Path(os.environ.get("VITIS_WORKSPACE", ROOT / "Vitis"))
XSA = ROOT / "hardware" / "baseline" / "qr_test_working_ver0.xsa"
SOURCE = ROOT / "software" / "vitis" / "Qr_barcode_working_ver0_app" / "src"
PLATFORM = "qr_verified_platform"
DOMAIN = "standalone_ps7_cortexa9_0"
APPLICATION = "Qr_barcode_working_ver0_app"
PLATFORM_XPFM = os.environ.get("VITIS_PLATFORM_XPFM")
BUILD_APPLICATION = os.environ.get("VITIS_BUILD_APPLICATION", "1") != "0"


def copy_application_sources(destination: Path) -> None:
    """Overlay the preserved application files without its stale app.yaml."""
    for source_path in SOURCE.rglob("*"):
        relative_path = source_path.relative_to(SOURCE)
        if relative_path == Path("app.yaml"):
            continue
        target_path = destination / relative_path
        if source_path.is_dir():
            target_path.mkdir(parents=True, exist_ok=True)
        else:
            target_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_path, target_path)


def main() -> None:
    if not XSA.is_file():
        raise FileNotFoundError(f"Baseline XSA not found: {XSA}")
    if not SOURCE.is_dir():
        raise FileNotFoundError(f"Application source not found: {SOURCE}")

    WORKSPACE.mkdir(exist_ok=True)
    client = vitis.create_client()
    try:
        client.set_workspace(str(WORKSPACE))

        if PLATFORM_XPFM:
            platform_xpfm = str(Path(PLATFORM_XPFM).resolve())
            if not Path(platform_xpfm).is_file():
                raise FileNotFoundError(f"Platform XPFM not found: {platform_xpfm}")
            client.add_platform_repos(str(Path(platform_xpfm).parent))
            platform_xpfm = client.find_platform_in_repos(PLATFORM)
        else:
            platform_names = [
                item.platform_name
                for item in client.list_platform_components().platformComponent
            ]
            if PLATFORM in platform_names:
                platform = client.get_component(PLATFORM)
            else:
                platform = client.create_platform_component(
                    name=PLATFORM,
                    hw_design=str(XSA),
                    cpu="ps7_cortexa9_0",
                    os="standalone",
                    domain_name=DOMAIN,
                )
            platform.build()
            platform_xpfm = client.find_platform_in_repos(PLATFORM)

        component_names = [item["name"] for item in client.list_components()]
        if APPLICATION in component_names:
            application = client.get_component(APPLICATION)
        else:
            application = client.create_app_component(
                name=APPLICATION,
                platform=platform_xpfm,
                domain=DOMAIN,
                template="hello_world",
            )
            copy_application_sources(Path(application.component_location) / "src")
        if BUILD_APPLICATION:
            application.build()
            print(f"Build completed: {Path(application.component_location) / 'build'}")
        else:
            print(f"Application prepared: {Path(application.component_location)}")
    finally:
        vitis.dispose()


if __name__ == "__main__":
    main()
