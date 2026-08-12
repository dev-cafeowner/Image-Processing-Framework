import sys
import struct
import zlib

import serial


WIDTH = 640
HEIGHT = 480
SIZE = WIDTH * HEIGHT


# ============================================================================
# PGM
# ============================================================================

def save_pgm(filename, data):
    with open(filename, "wb") as f:
        f.write(
            f"P5\n{WIDTH} {HEIGHT}\n255\n".encode("ascii")
        )

        f.write(data)


# ============================================================================
# PNG
#
# Pure Python standard-library grayscale PNG writer.
# No Pillow required.
# ============================================================================

def png_chunk(chunk_type, data):
    chunk = chunk_type + data

    crc = zlib.crc32(chunk) & 0xFFFFFFFF

    return (
        struct.pack(">I", len(data))
        + chunk
        + struct.pack(">I", crc)
    )


def save_png(filename, data):
    signature = b"\x89PNG\r\n\x1a\n"

    ihdr = struct.pack(
        ">IIBBBBB",
        WIDTH,
        HEIGHT,
        8,      # bit depth
        0,      # grayscale
        0,      # compression
        0,      # filter
        0       # interlace
    )

    raw_rows = bytearray()

    for y in range(HEIGHT):
        start = y * WIDTH
        end = start + WIDTH

        # filter type 0
        raw_rows.append(0)

        raw_rows.extend(
            data[start:end]
        )

    compressed = zlib.compress(
        bytes(raw_rows),
        level=6
    )

    with open(filename, "wb") as f:
        f.write(signature)

        f.write(
            png_chunk(
                b"IHDR",
                ihdr
            )
        )

        f.write(
            png_chunk(
                b"IDAT",
                compressed
            )
        )

        f.write(
            png_chunk(
                b"IEND",
                b""
            )
        )


# ============================================================================
# Normalize
# ============================================================================

def normalize_gray(data):
    min_v = min(data)
    max_v = max(data)

    total = sum(data)

    mean_v = total / len(data)

    print(
        f"[PC] min/max/mean = "
        f"{min_v} / {max_v} / {mean_v:.2f}"
    )

    if max_v <= min_v:
        return bytes(data)

    result = bytearray(
        len(data)
    )

    value_range = max_v - min_v

    for i, value in enumerate(data):
        v = (
            (value - min_v) * 255
        ) // value_range

        if v < 0:
            v = 0

        elif v > 255:
            v = 255

        result[i] = v

    return bytes(result)


# ============================================================================
# Read exactly N bytes
# ============================================================================

def read_exact(ser, size, label):
    data = bytearray()

    next_report = 32768

    while len(data) < size:
        chunk = ser.read(
            size - len(data)
        )

        if not chunk:
            continue

        data.extend(
            chunk
        )

        if len(data) >= next_report:
            print(
                f"[PC] {label}: "
                f"{len(data)} / {size}"
            )

            next_report += 32768

    return bytes(data)


# ============================================================================
# Wait for marker
# ============================================================================

def wait_for_marker(ser, marker):
    print()
    print(
        f"[PC] Waiting for {marker}..."
    )

    while True:
        line = ser.readline()

        if not line:
            continue

        text = line.decode(
            "ascii",
            errors="replace"
        ).rstrip()

        print(text)

        if text.startswith(marker):
            parts = text.split()

            if len(parts) >= 4:
                width = int(parts[1])
                height = int(parts[2])
                size = int(parts[3])

                print(
                    f"[PC] Header: "
                    f"{width}x{height}, "
                    f"{size} bytes"
                )

                if width != WIDTH:
                    raise RuntimeError(
                        f"Unexpected width {width}"
                    )

                if height != HEIGHT:
                    raise RuntimeError(
                        f"Unexpected height {height}"
                    )

                if size != SIZE:
                    raise RuntimeError(
                        f"Unexpected size {size}"
                    )

            return


# ============================================================================
# Save one frame
# ============================================================================

def save_frame(prefix, data):
    print()
    print(
        f"[PC] Processing {prefix}"
    )

    normalized = normalize_gray(
        data
    )

    raw_pgm = (
        f"{prefix}_raw.pgm"
    )

    norm_pgm = (
        f"{prefix}_norm.pgm"
    )

    raw_png = (
        f"{prefix}_raw.png"
    )

    norm_png = (
        f"{prefix}_norm.png"
    )


    save_pgm(
        raw_pgm,
        data
    )


    save_pgm(
        norm_pgm,
        normalized
    )


    save_png(
        raw_png,
        data
    )


    save_png(
        norm_png,
        normalized
    )


    print(
        "[PASS] Saved:"
    )

    print(
        f"       {raw_pgm}"
    )

    print(
        f"       {norm_pgm}"
    )

    print(
        f"       {raw_png}"
    )

    print(
        f"       {norm_png}"
    )


# ============================================================================
# Main
# ============================================================================

def main():
    if len(sys.argv) != 2:
        print(
            f"Usage: "
            f"{sys.argv[0]} "
            f"/dev/ttyUSBx"
        )

        sys.exit(1)


    port = sys.argv[1]


    print(
        f"[PC] Opening "
        f"{port} @ 115200"
    )


    ser = serial.Serial(
        port=port,
        baudrate=115200,
        timeout=1
    )


    ser.reset_input_buffer()


    print(
        "[PC] Waiting for Zybo..."
    )


    print(
        "[PC] Now press Run in Vitis."
    )


    # ========================================================================
    # Frame 1:
    # Exact-Sync Gray8
    # ========================================================================

    wait_for_marker(
        ser,
        "GRAY8_BEGIN"
    )


    print(
        "[PC] Receiving "
        "Exact-Sync Gray8..."
    )


    exact_data = read_exact(
        ser,
        SIZE,
        "Exact Gray8"
    )


    print(
        f"[PASS] Exact Gray8 received: "
        f"{len(exact_data)} bytes"
    )


    save_frame(
        "exact_gray",
        exact_data
    )


    # ========================================================================
    # Frame 2:
    # VDMA RGB888 -> Gray
    # ========================================================================

    wait_for_marker(
        ser,
        "VDMA_GRAY_BEGIN"
    )


    print(
        "[PC] Receiving "
        "VDMA RGB -> Gray..."
    )


    vdma_data = read_exact(
        ser,
        SIZE,
        "VDMA Gray"
    )


    print(
        f"[PASS] VDMA Gray received: "
        f"{len(vdma_data)} bytes"
    )


    save_frame(
        "vdma_gray",
        vdma_data
    )


    # ========================================================================
    # Remaining UART log
    # ========================================================================

    print()
    print(
        "[PC] Remaining UART output:"
    )


    empty_count = 0


    while empty_count < 5:
        line = ser.readline()


        if not line:
            empty_count += 1

            continue


        empty_count = 0


        text = line.decode(
            "ascii",
            errors="replace"
        ).rstrip()


        print(
            text
        )


    ser.close()


    print()
    print(
        "===================================="
    )

    print(
        " Capture complete"
    )

    print(
        "===================================="
    )

    print()
    print(
        "Compare these two first:"
    )

    print(
        "  exact_gray_norm.png"
    )

    print(
        "  vdma_gray_norm.png"
    )


if __name__ == "__main__":
    main()