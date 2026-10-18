"""Pixel-level Kitty presentation checks through real GTK/PTYS on X11.

Requires python3-pil and xdotool. GDK_SCALE=2 checks native HiDPI rendering.
Pixel checks default to Cairo; set GSK_RENDERER=gl to exercise GTK's GL path.
Set ZIGONAUT_IMAGE_ARTIFACTS to save review screenshots and a layout recording.
"""
import base64
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageChops, ImageGrab


def xdo(*args):
    return subprocess.check_output(["xdotool", *map(str, args)], text=True).strip()


def wait(predicate, description):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(description)


def kitty(options, data=b""):
    return b"\x1b_Gq=2," + options.encode() + b";" + base64.b64encode(data) + b"\x1b\\"


def at(row, col):
    return f"\x1b[{row};{col}H".encode()


def bounds(image, colour):
    channels = ImageChops.difference(image, Image.new("RGB", image.size, colour)).split()
    mask = ImageChops.lighter(ImageChops.lighter(channels[0], channels[1]), channels[2])
    return mask.point(lambda v: 255 if v == 0 else 0).getbbox()


artifacts = os.environ.get("ZIGONAUT_IMAGE_ARTIFACTS")
if artifacts:
    artifacts = Path(artifacts).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="zigonaut-images-") as directory:
    root = Path(directory)
    config = root / "config" / "zigonaut"
    config.mkdir(parents=True)
    (config / "settings.ini").write_text("[Settings]\nversion=1\nfont=Monospace\nlightTheme=0\ndarkTheme=0\n"
        "profileCount=1\ndefaultProfile=0\n[Profile 0]\nname=Default\nshell=/bin/sh\ncommand=\ndirectory=\n")
    env = dict(os.environ, SHELL="/bin/sh", PS1="", GDK_BACKEND="x11", GDK_SCALE="2",
               XDG_CONFIG_HOME=str(root / "config"), GTK_A11Y="none", G_DEBUG="fatal-warnings")
    env.setdefault("GSK_RENDERER", "cairo")
    with (root / "stderr").open("w+") as log:
        app = subprocess.Popen([str(Path(sys.argv[1]).resolve())], cwd=root, env=env, stdout=log, stderr=log)
        recording = None
        try:
            windows = []

            def find_window():
                result = subprocess.run(["xdotool", "search", "--onlyvisible", "--pid", str(app.pid)],
                                        text=True, capture_output=True)
                windows[:] = result.stdout.splitlines()[:1]
                return bool(windows)

            wait(find_window, "GTK window")
            window = windows[0]
            xdo("windowfocus", "--sync", window)

            def command(text):
                xdo("type", "--clearmodifiers", "--delay", 1, text)
                xdo("key", "Return")

            def emit(data):
                path = root / "frame"
                path.write_bytes(data)
                done = root / "done"
                done.unlink(missing_ok=True)
                command("cat frame; echo done > done")
                wait(done.exists, "PTY image output")
                time.sleep(0.3)

            def screenshot(name=None):
                geometry = dict(line.split("=", 1) for line in xdo("getwindowgeometry", "--shell", window).splitlines())
                x, y, w, h = (int(geometry[k]) for k in ("X", "Y", "WIDTH", "HEIGHT"))
                image = ImageGrab.grab(xdisplay=os.environ["DISPLAY"]).convert("RGB").crop((x, y, x + w, y + h))
                if artifacts and name:
                    image.save(artifacts / f"{name}.png")
                return image

            command("stty -echo; echo ready > ready")
            wait(lambda: (root / "ready").exists(), "raw display setup")
            rgba = bytes([240, 40, 80, 128, 10, 200, 90, 255, 70, 30, 220, 0,
                          20, 60, 210, 255, 200, 100, 30, 64, 1, 2, 3, 255])
            png = io.BytesIO()
            Image.frombytes("RGBA", (3, 2), rgba).save(png, format="PNG")
            frame = b"\x1b[2J\x1b[?25l" + at(1, 1) + b"Kitty: RGBA / PNG crop / solid RGBA / Unicode placeholder"
            frame += at(3, 3) + kitty("a=T,f=32,s=3,v=2,i=7,c=18,r=6,C=1", rgba)
            frame += at(3, 25) + kitty("a=T,f=100,i=8,c=8,r=4,x=1,y=1,w=1,h=1,C=1", png.getvalue())
            frame += at(9, 3) + kitty("a=T,f=32,s=1,v=1,i=9,c=8,r=3,C=1", bytes([35, 170, 230, 255]))
            # Shared snapshots intentionally omit non-RGBA and negative-z images.
            frame += at(9, 15) + kitty("a=T,f=24,s=1,v=1,i=11,c=2,r=1,C=1", bytes([11, 22, 33]))
            frame += at(10, 15) + kitty("a=T,f=32,s=1,v=1,i=12,c=2,r=1,C=1,z=-1", bytes([44, 55, 66, 255]))
            frame += kitty("a=T,U=1,f=32,s=1,v=1,i=10,c=1,r=1", bytes([190, 50, 170, 255]))
            frame += at(9, 25) + b"\x1b[38;2;0;0;10m\xf4\x8e\xbb\xae\x1b[0m"  # U+10EEEE
            frame += at(14, 1) + b"Images stay with their PTY across split, zoom and transfer."
            emit(frame)
            image = screenshot("kitty-default-2x")
            # Independent expected composites over Rasmus #1a1a19.
            assert bounds(image, (133, 33, 52)), "RGBA half-alpha/channel conversion"
            assert bounds(image, (69, 44, 27)), "PNG crop/quarter-alpha"
            assert bounds(image, (20, 60, 210)), "Asymmetric bottom row"
            assert bounds(image, (35, 170, 230)), "Solid RGBA transport"
            assert not bounds(image, (11, 22, 33)) and not bounds(image, (44, 55, 66)), "Shared subset changed"
            assert bounds(image, (190, 50, 170)), "Unicode placeholder"
            blue_region = bounds(image, (35, 170, 230))
            emit(at(10, 4) + b"\x1b[6 q\x1b[?25h")
            assert bounds(screenshot("kitty-cursor-2x").crop(blue_region), (209, 209, 209)), "Cursor covered by image"
            emit(b"\x1b[?25l")
            xdo("key", "ctrl+shift+f")
            time.sleep(0.3)
            xdo("type", "Kitty")
            time.sleep(0.4)
            xdo("key", "Return")
            time.sleep(0.3)
            searching = screenshot("kitty-find-2x")
            assert bounds(searching, (200, 161, 90)) and bounds(searching, (35, 170, 230)), "Find/image layering"
            xdo("key", "Escape")
            time.sleep(0.3)
            crop_region = (image.width // 4, 0, image.width, image.height)
            old = bounds(image.crop(crop_region), (69, 44, 27))
            # Retransmission removes old placements; explicitly replace at the
            # same position with the same ID and dimensions but changed pixels.
            changed = bytearray(rgba)
            changed[16:20] = bytes([200, 100, 30, 255])
            emit(at(3, 25) + kitty("a=T,f=32,s=3,v=2,i=8,c=8,r=4,x=1,y=1,w=1,h=1,C=1", changed))
            image = screenshot("kitty-replacement-2x")
            assert not bounds(image.crop(crop_region), (69, 44, 27)), "Stale-generation surface"
            assert bounds(image.crop(crop_region), (200, 100, 30)) == old, "Replacement changed placement"
            emit(kitty("a=d,d=I,i=8"))
            assert not bounds(screenshot(), (200, 100, 30)), "Deleted image still visible"

            # Scroll a placement partly above the viewport, then restore it.
            emit(at(24, 1) + b"\r\n" * 23)
            assert not bounds(screenshot(), (35, 170, 230)), "Image did not leave viewport"
            xdo("key", "shift+Page_Up", "shift+Page_Up")
            time.sleep(0.3)
            assert bounds(screenshot("kitty-scrollback-2x"), (35, 170, 230)), "Image lost in scrollback"
            xdo("key", "shift+Page_Down", "shift+Page_Down")
            emit(kitty("a=d,d=A") + frame)

            if artifacts:
                # x11grab includes the actual X pointer while it moves between panes.
                recording = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-y", "-f", "x11grab",
                    "-video_size", "1800x1300", "-framerate", "20", "-i", os.environ["DISPLAY"],
                    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                    str(artifacts / "kitty-layout-2x.mp4")], stdin=subprocess.PIPE)
                time.sleep(0.8)

            xdo("key", "ctrl+shift+o")
            time.sleep(0.4)
            command("stty -echo; echo second > second")
            wait(lambda: (root / "second").exists(), "Independent split PTY")
            emit(b"\x1b[2J\x1b[?25l" + at(1, 1) + b"Independent pane: same image ID, different pixels" +
                 at(3, 3) + kitty("a=T,f=32,s=1,v=1,i=7,c=10,r=4,C=1", bytes([220, 180, 15, 255])))
            split = screenshot("kitty-split-2x")
            assert bounds(split, (35, 170, 230)) and bounds(split, (220, 180, 15)), "Pane image isolation"
            for x in range(200, 1500, 40):
                xdo("mousemove", "--window", window, x, 400)
                time.sleep(0.02)
            xdo("key", "ctrl+shift+Return")
            time.sleep(1.2 if recording else 0.4)
            zoom = screenshot("kitty-zoom-2x")
            assert not bounds(zoom, (35, 170, 230)) and bounds(zoom, (220, 180, 15)), "Zoom visibility"
            xdo("key", "ctrl+shift+Return")
            time.sleep(1.0 if recording else 0.3)
            # Changing font metrics recomputes destination placement sizes.
            before = bounds(screenshot(), (220, 180, 15))
            xdo("key", "ctrl+plus", "ctrl+plus")
            time.sleep(0.4)
            after = bounds(screenshot("kitty-metrics-2x"), (220, 180, 15))
            assert after[2] - after[0] > before[2] - before[0], (before, after)
            if recording:
                for x in range(200, 1640, 35):
                    xdo("mousemove", "--window", window, x, 45)
                    time.sleep(0.025)
                time.sleep(0.8)
            # Transfer the split tab with live images to a new GTK window.
            # Keep the pointer out of the popover so hover cannot select a
            # different menu row while keyboard navigation is in progress.
            xdo("mousemove", "--window", window, 800, 55)
            xdo("key", "F10")
            time.sleep(1.0 if recording else 0.4)
            xdo("key", "Home", "Down", "Return")
            destination = []

            def transferred_window():
                result = subprocess.run(["xdotool", "search", "--all", "--onlyvisible", "--pid", str(app.pid),
                                         "--name", "^Terminal$"], text=True, capture_output=True)
                destination[:] = [w for w in result.stdout.splitlines() if w != window]
                return bool(destination)

            wait(transferred_window, "Images transferred to a distinct GTK window")
            window = destination[0]
            if recording:
                xdo("windowmove", "--sync", window, 80, 120)

            def images_visible():
                image = screenshot()
                return bounds(image, (35, 170, 230)) and bounds(image, (220, 180, 15))

            wait(images_visible, "Transferred images painted in the destination window")
            transferred = screenshot("kitty-transferred-2x")
            assert bounds(transferred, (35, 170, 230)) and bounds(transferred, (220, 180, 15)), "Transfer lost images"
            if recording:
                time.sleep(3)
                recording.communicate(b"q", timeout=10)
                assert recording.returncode == 0
                recording = None
            print("Kitty GTK E2E passed at native 2x: RGBA/PNG, exact alpha and crop pixels, Unicode placeholder, "
                  "cursor/Find layering, same-ID replacement, deletion, scrollback, isolated split images, zoom, "
                  f"font image width {before[2] - before[0]} → {after[2] - after[0]} px, distinct-window tab transfer; "
                  "raw RGB and negative-z omissions preserved")
        finally:
            if recording:
                recording.communicate(b"q", timeout=10)
            app.terminate()
            app.wait(timeout=5)
            log.seek(0)
            errors = log.read()
            if errors:
                print(errors, file=sys.stderr)
