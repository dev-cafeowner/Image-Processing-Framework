import sys
import time
import queue
import threading
import tkinter as tk
import os
import struct
import zlib
from datetime import datetime

import serial


# =============================================================================
# Configuration
# =============================================================================

PREVIEW_WIDTH = 160
PREVIEW_HEIGHT = 120

PACKED_BYTES = PREVIEW_WIDTH * PREVIEW_HEIGHT // 2

DISPLAY_SCALE = 4

DISPLAY_WIDTH = PREVIEW_WIDTH * DISPLAY_SCALE
DISPLAY_HEIGHT = PREVIEW_HEIGHT * DISPLAY_SCALE

BAUD = 115200

# 카메라 영상 방향 보정
ROTATE_180 = True

CAPTURE_DIR = "captures"


# =============================================================================
# Serial -> GUI queue
#
# GUI가 UART보다 느려져도 가장 최신 프레임만 표시한다.
# =============================================================================

frame_queue = queue.Queue(maxsize=1)


# =============================================================================
# 4-bit gray -> 8-bit gray
#
# UART packet:
#
# byte[7:4] = pixel N
# byte[3:0] = pixel N+1
# =============================================================================

def unpack_gray4(data):
    frame = bytearray(
        PREVIEW_WIDTH * PREVIEW_HEIGHT
    )

    dst = 0

    for value in data:
        high = (value >> 4) & 0x0F
        low = value & 0x0F

        frame[dst] = high * 17
        frame[dst + 1] = low * 17

        dst += 2

    return frame


# =============================================================================
# Rotate frame 180 degrees
# =============================================================================

def rotate_frame_180(frame):
    return bytearray(
        reversed(frame)
    )


# =============================================================================
# Focus score
#
# 간단한 수평/수직 gradient 평균.
#
# 동일한 장면에서 렌즈만 돌릴 때:
#
# Focus 값 증가 -> 대체로 선명도 증가
#
# 절대값보다 변화 추세를 본다.
# =============================================================================

def calculate_focus_score(frame):
    total = 0
    count = 0

    width = PREVIEW_WIDTH
    height = PREVIEW_HEIGHT

    for y in range(1, height - 1):
        row = y * width

        for x in range(1, width - 1):
            index = row + x

            dx = abs(
                int(frame[index + 1])
                - int(frame[index - 1])
            )

            dy = abs(
                int(frame[index + width])
                - int(frame[index - width])
            )

            total += dx + dy
            count += 1

    if count == 0:
        return 0.0

    return total / count


# =============================================================================
# Tkinter grayscale palette
#
# 현재 UART 영상 자체가 4-bit Gray이므로 실제 값은
# 0, 17, 34, ... 255 중 하나다.
# =============================================================================

GRAY_PALETTE = tuple(
    f"#{value:02x}{value:02x}{value:02x}"
    for value in range(0, 256, 17)
)


# =============================================================================
# Tk PhotoImage 생성
#
# PGM decoder를 사용하지 않는다.
# PhotoImage에 픽셀을 직접 입력한다.
# =============================================================================

def make_photo(frame):
    image = tk.PhotoImage(
        width=PREVIEW_WIDTH,
        height=PREVIEW_HEIGHT
    )

    rows = []

    for y in range(PREVIEW_HEIGHT):
        start = y * PREVIEW_WIDTH
        end = start + PREVIEW_WIDTH

        row = frame[start:end]

        colors = [
            GRAY_PALETTE[value >> 4]
            for value in row
        ]

        rows.append(
            "{" + " ".join(colors) + "}"
        )

    image.put(
        " ".join(rows)
    )

    enlarged = image.zoom(
        DISPLAY_SCALE,
        DISPLAY_SCALE
    )

    return enlarged


# =============================================================================
# Initial black image
# =============================================================================

def make_blank_photo():
    image = tk.PhotoImage(
        width=DISPLAY_WIDTH,
        height=DISPLAY_HEIGHT
    )

    image.put(
        "#000000",
        to=(
            0,
            0,
            DISPLAY_WIDTH,
            DISPLAY_HEIGHT
        )
    )

    return image


# =============================================================================
# PNG writer
#
# Pillow 필요 없음.
# Python 표준 라이브러리만 사용.
# =============================================================================

def png_chunk(chunk_type, data):
    chunk = chunk_type + data

    crc = zlib.crc32(chunk) & 0xFFFFFFFF

    return (
        struct.pack(">I", len(data))
        + chunk
        + struct.pack(">I", crc)
    )


def save_gray_png(
    filename,
    frame,
    width,
    height
):
    signature = b"\x89PNG\r\n\x1a\n"

    ihdr = struct.pack(
        ">IIBBBBB",
        width,
        height,
        8,      # bit depth
        0,      # grayscale
        0,      # compression
        0,      # filter
        0       # interlace
    )

    raw = bytearray()

    for y in range(height):
        start = y * width
        end = start + width

        # PNG filter type 0
        raw.append(0)

        raw.extend(
            frame[start:end]
        )

    compressed = zlib.compress(
        bytes(raw),
        level=6
    )

    with open(filename, "wb") as file:
        file.write(signature)

        file.write(
            png_chunk(
                b"IHDR",
                ihdr
            )
        )

        file.write(
            png_chunk(
                b"IDAT",
                compressed
            )
        )

        file.write(
            png_chunk(
                b"IEND",
                b""
            )
        )


# =============================================================================
# Nearest-neighbor upscale
#
# 저장용:
#
# 160x120 -> 640x480
# =============================================================================

def upscale_frame(
    frame,
    scale
):
    src_width = PREVIEW_WIDTH
    src_height = PREVIEW_HEIGHT

    dst_width = src_width * scale
    dst_height = src_height * scale

    output = bytearray(
        dst_width * dst_height
    )

    for sy in range(src_height):
        for sx in range(src_width):
            value = frame[
                sy * src_width + sx
            ]

            base_x = sx * scale
            base_y = sy * scale

            for dy in range(scale):
                dst_row = (
                    (base_y + dy)
                    * dst_width
                )

                for dx in range(scale):
                    output[
                        dst_row
                        + base_x
                        + dx
                    ] = value

    return (
        output,
        dst_width,
        dst_height
    )


# =============================================================================
# Read exactly N binary bytes
# =============================================================================

def read_exact(
    serial_port,
    size
):
    data = bytearray()

    while len(data) < size:
        chunk = serial_port.read(
            size - len(data)
        )

        if chunk:
            data.extend(chunk)

    return bytes(data)


# =============================================================================
# Serial thread
# =============================================================================

def serial_worker(port):
    print(
        f"[PC] Opening {port} @ {BAUD}"
    )

    serial_port = serial.Serial(
        port=port,
        baudrate=BAUD,
        timeout=1
    )

    serial_port.reset_input_buffer()

    print(
        "[PC] Waiting for PREVIEW_BEGIN..."
    )

    print(
        "[PC] Now press Run in Vitis."
    )

    while True:
        try:
            line = serial_port.readline()

            if not line:
                continue

            text = line.decode(
                "ascii",
                errors="ignore"
            ).strip()

            # ---------------------------------------------------------------
            # PREVIEW_END는 매 프레임마다 발생하므로 출력하지 않는다.
            # ---------------------------------------------------------------

            if text == "PREVIEW_END":
                continue

            # ---------------------------------------------------------------
            # PREVIEW_BEGIN 이외의 문자열은 일반 UART 로그
            # ---------------------------------------------------------------

            if not text.startswith(
                "PREVIEW_BEGIN"
            ):
                if text:
                    print(text)

                continue

            # ---------------------------------------------------------------
            # Header
            #
            # PREVIEW_BEGIN width height bytes frame_no
            # ---------------------------------------------------------------

            parts = text.split()

            if len(parts) < 5:
                print(
                    "[WARN] Invalid preview header:",
                    text
                )
                continue

            width = int(parts[1])
            height = int(parts[2])
            size = int(parts[3])
            frame_number = int(parts[4])

            if (
                width != PREVIEW_WIDTH
                or height != PREVIEW_HEIGHT
                or size != PACKED_BYTES
            ):
                print(
                    "[ERROR] Preview format mismatch:",
                    text
                )
                continue

            # ---------------------------------------------------------------
            # Raw packed Gray4 payload
            # ---------------------------------------------------------------

            packed = read_exact(
                serial_port,
                size
            )

            frame = unpack_gray4(
                packed
            )

            if ROTATE_180:
                frame = rotate_frame_180(
                    frame
                )

            # ---------------------------------------------------------------
            # Queue에는 최신 프레임 한 장만 유지
            # ---------------------------------------------------------------

            try:
                frame_queue.put_nowait(
                    (
                        frame_number,
                        frame
                    )
                )

            except queue.Full:
                try:
                    frame_queue.get_nowait()
                except queue.Empty:
                    pass

                frame_queue.put_nowait(
                    (
                        frame_number,
                        frame
                    )
                )

        except Exception as error:
            print(
                "[SERIAL ERROR]",
                error
            )

            time.sleep(1.0)


# =============================================================================
# GUI
# =============================================================================

class PreviewWindow:
    def __init__(
        self,
        root
    ):
        self.root = root

        self.root.title(
            "OV7670 Live Preview + Capture"
        )

        # ---------------------------------------------------------------------
        # Current live state
        # ---------------------------------------------------------------------

        self.current_frame = None
        self.current_frame_number = 0
        self.current_focus = 0.0

        self.last_time = None

        # ---------------------------------------------------------------------
        # Keep PhotoImage references
        # ---------------------------------------------------------------------

        self.live_photo = make_blank_photo()
        self.capture_photo = make_blank_photo()

        # ---------------------------------------------------------------------
        # Capture directory
        # ---------------------------------------------------------------------

        os.makedirs(
            CAPTURE_DIR,
            exist_ok=True
        )

        # ---------------------------------------------------------------------
        # Window title
        # ---------------------------------------------------------------------

        title = tk.Label(
            root,
            text="OV7670 LIVE FOCUS / CAPTURE",
            font=(
                "Monospace",
                16,
                "bold"
            )
        )

        title.pack(
            pady=8
        )

        # ---------------------------------------------------------------------
        # Image area
        # ---------------------------------------------------------------------

        image_area = tk.Frame(
            root
        )

        image_area.pack(
            padx=10,
            pady=5
        )

        # =====================================================================
        # LIVE VIEW
        # =====================================================================

        live_frame = tk.Frame(
            image_area
        )

        live_frame.grid(
            row=0,
            column=0,
            padx=8,
            sticky="n"
        )

        live_title = tk.Label(
            live_frame,
            text="LIVE VIEW",
            font=(
                "Monospace",
                13,
                "bold"
            )
        )

        live_title.pack(
            pady=3
        )

        self.live_label = tk.Label(
            live_frame,
            image=self.live_photo,
            background="black",
            borderwidth=2,
            relief="sunken"
        )

        self.live_label.pack()

        # =====================================================================
        # LAST CAPTURE
        # =====================================================================

        capture_frame = tk.Frame(
            image_area
        )

        capture_frame.grid(
            row=0,
            column=1,
            padx=8,
            sticky="n"
        )

        capture_title = tk.Label(
            capture_frame,
            text="LAST CAPTURE",
            font=(
                "Monospace",
                13,
                "bold"
            )
        )

        capture_title.pack(
            pady=3
        )

        self.capture_label = tk.Label(
            capture_frame,
            image=self.capture_photo,
            background="black",
            borderwidth=2,
            relief="sunken"
        )

        self.capture_label.pack()

        # ---------------------------------------------------------------------
        # Live status
        # ---------------------------------------------------------------------

        self.status_label = tk.Label(
            root,
            text="Waiting for camera...",
            font=(
                "Monospace",
                13
            )
        )

        self.status_label.pack(
            pady=6
        )

        # ---------------------------------------------------------------------
        # Capture status
        # ---------------------------------------------------------------------

        self.capture_status = tk.Label(
            root,
            text="Capture: none",
            font=(
                "Monospace",
                10
            )
        )

        self.capture_status.pack(
            pady=2
        )

        # ---------------------------------------------------------------------
        # Buttons
        # ---------------------------------------------------------------------

        button_frame = tk.Frame(
            root
        )

        button_frame.pack(
            pady=8
        )

        capture_button = tk.Button(
            button_frame,
            text="CAPTURE  [SPACE]",
            font=(
                "Monospace",
                12,
                "bold"
            ),
            width=20,
            command=self.capture
        )

        capture_button.grid(
            row=0,
            column=0,
            padx=5
        )

        quit_button = tk.Button(
            button_frame,
            text="QUIT  [ESC]",
            font=(
                "Monospace",
                12
            ),
            width=15,
            command=self.root.destroy
        )

        quit_button.grid(
            row=0,
            column=1,
            padx=5
        )

        # ---------------------------------------------------------------------
        # Help
        # ---------------------------------------------------------------------

        help_label = tk.Label(
            root,
            text=(
                "렌즈를 돌리면서 왼쪽 LIVE 영상의 글자/QR 경계를 확인하세요.\n"
                "SPACE = 현재 LIVE 프레임을 오른쪽에 고정 + PNG 저장"
            ),
            font=(
                "Monospace",
                10
            )
        )

        help_label.pack(
            pady=5
        )

        # ---------------------------------------------------------------------
        # Keyboard shortcuts
        # ---------------------------------------------------------------------

        self.root.bind(
            "<space>",
            self.capture
        )

        self.root.bind(
            "<Escape>",
            lambda event:
                self.root.destroy()
        )

        # ---------------------------------------------------------------------
        # Start GUI update
        # ---------------------------------------------------------------------

        self.update_live()


    # =========================================================================
    # Capture current frame
    # =========================================================================

    def capture(
        self,
        event=None
    ):
        if self.current_frame is None:
            self.capture_status.configure(
                text="Capture: no live frame"
            )

            return

        # ---------------------------------------------------------------------
        # Independent copy
        # ---------------------------------------------------------------------

        captured = bytearray(
            self.current_frame
        )

        # ---------------------------------------------------------------------
        # Display captured frame on right panel
        # ---------------------------------------------------------------------

        self.capture_photo = make_photo(
            captured
        )

        self.capture_label.configure(
            image=self.capture_photo
        )

        # ---------------------------------------------------------------------
        # Filename
        # ---------------------------------------------------------------------

        timestamp = datetime.now().strftime(
            "%Y%m%d_%H%M%S_%f"
        )

        base_name = (
            f"capture_"
            f"{timestamp}_"
            f"frame{self.current_frame_number}"
        )

        native_filename = os.path.join(
            CAPTURE_DIR,
            base_name
            + "_160x120.png"
        )

        full_filename = os.path.join(
            CAPTURE_DIR,
            base_name
            + "_640x480.png"
        )

        # ---------------------------------------------------------------------
        # Save native preview
        # ---------------------------------------------------------------------

        save_gray_png(
            native_filename,
            captured,
            PREVIEW_WIDTH,
            PREVIEW_HEIGHT
        )

        # ---------------------------------------------------------------------
        # Save enlarged 640x480 preview
        # ---------------------------------------------------------------------

        (
            enlarged,
            enlarged_width,
            enlarged_height
        ) = upscale_frame(
            captured,
            4
        )

        save_gray_png(
            full_filename,
            enlarged,
            enlarged_width,
            enlarged_height
        )

        # ---------------------------------------------------------------------
        # GUI status
        # ---------------------------------------------------------------------

        self.capture_status.configure(
            text=(
                f"Captured Frame "
                f"{self.current_frame_number}    "
                f"Focus "
                f"{self.current_focus:.2f}\n"
                f"{full_filename}"
            )
        )

        # ---------------------------------------------------------------------
        # Terminal
        # ---------------------------------------------------------------------

        print()
        print(
            "========================================"
        )
        print(
            "[CAPTURE]"
        )

        print(
            f"Frame : "
            f"{self.current_frame_number}"
        )

        print(
            f"Focus : "
            f"{self.current_focus:.2f}"
        )

        print(
            f"Saved : "
            f"{native_filename}"
        )

        print(
            f"Saved : "
            f"{full_filename}"
        )

        print(
            "========================================"
        )


    # =========================================================================
    # Update LIVE view
    # =========================================================================

    def update_live(self):
        newest = None

        # ---------------------------------------------------------------------
        # Consume all queued images and use newest only
        # ---------------------------------------------------------------------

        while True:
            try:
                newest = frame_queue.get_nowait()

            except queue.Empty:
                break

        # ---------------------------------------------------------------------
        # New frame received
        # ---------------------------------------------------------------------

        if newest is not None:
            frame_number, frame = newest

            focus_score = calculate_focus_score(
                frame
            )

            self.current_frame = frame
            self.current_frame_number = frame_number
            self.current_focus = focus_score

            # -----------------------------------------------------------------
            # FPS
            # -----------------------------------------------------------------

            now = time.time()

            if self.last_time is None:
                fps = 0.0

            else:
                delta = now - self.last_time

                if delta > 0.0:
                    fps = 1.0 / delta
                else:
                    fps = 0.0

            self.last_time = now

            # -----------------------------------------------------------------
            # Create and display LIVE image
            # -----------------------------------------------------------------

            try:
                self.live_photo = make_photo(
                    frame
                )

                self.live_label.configure(
                    image=self.live_photo
                )

            except tk.TclError as error:
                self.status_label.configure(
                    text=(
                        f"Tk image error: "
                        f"{error}"
                    )
                )

                print(
                    "[Tk image error]",
                    error
                )

            # -----------------------------------------------------------------
            # Status
            # -----------------------------------------------------------------

            self.status_label.configure(
                text=(
                    f"LIVE Frame "
                    f"{frame_number}    "
                    f"Focus "
                    f"{focus_score:.2f}    "
                    f"{fps:.2f} fps"
                )
            )

        # ---------------------------------------------------------------------
        # Run again after 50 ms
        # ---------------------------------------------------------------------

        self.root.after(
            50,
            self.update_live
        )


# =============================================================================
# Main
# =============================================================================

def main():
    if len(sys.argv) != 2:
        print(
            f"Usage: "
            f"{sys.argv[0]} "
            f"/dev/ttyUSBx"
        )

        sys.exit(1)

    port = sys.argv[1]

    # -------------------------------------------------------------------------
    # Serial thread
    # -------------------------------------------------------------------------

    worker = threading.Thread(
        target=serial_worker,
        args=(port,),
        daemon=True
    )

    worker.start()

    # -------------------------------------------------------------------------
    # GUI
    # -------------------------------------------------------------------------

    root = tk.Tk()

    PreviewWindow(
        root
    )

    root.mainloop()


if __name__ == "__main__":
    main()