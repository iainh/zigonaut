"""Native GTK pointer/PTY contract. Run on X11 in a private D-Bus session.

Requires xdotool, xclip, ImageMagick and the distribution's python3-pyatspi/Pillow. Optional
ZGTK_POINTER_ARTIFACTS captures the real GTK window (use GDK_SCALE=2).
ZGTK_POINTER_RECORD=1 additionally records a native pointer tour with ffmpeg.
"""
import json
import os
from pathlib import Path
import re
import select
import shlex
import subprocess
import sys
import tempfile
import time
import tty


def fixture(root):
    """A real raw-mode PTY peer, controlled out of band, not a mock ABI."""
    tty.setraw(0)
    pid = str(os.getpid())
    (root / f"{pid}.ready").touch()
    previous = None
    with (root / f"{pid}.input").open("ab", buffering=0) as output:
        while True:
            control = root / f"{pid}.control"
            if control.exists():
                request = json.loads(control.read_text())
                if request != previous:
                    os.write(1, request[1].encode())
                    (root / f"{pid}.ack").write_text(str(request[0]))
                    previous = request
            if select.select([0], [], [], 0.02)[0]:
                data = os.read(0, 4096)
                if not data:
                    return
                output.write(data)


if len(sys.argv) == 3 and sys.argv[1] == "--fixture":
    fixture(Path(sys.argv[2]))
    sys.exit(0)

import pyatspi
from PIL import Image


def xdo(*args):
    return subprocess.check_output(["xdotool", *map(str, args)], text=True).strip()


def wait_for(predicate, description):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(f"Timed out: {description}")


def nodes(root=None):
    if root is None:
        root = pyatspi.Registry.getDesktop(0)
    yield root
    for child in root:
        yield from nodes(child)


with tempfile.TemporaryDirectory(prefix="zigonaut-pointer-") as directory:
    root = Path(directory)
    config = root / "config/zigonaut/settings.ini"
    config.parent.mkdir(parents=True)
    command = shlex.join([sys.executable, str(Path(__file__).resolve()), "--fixture", str(root)])
    config.write_text(f"[Settings]\nversion=1\nprofileCount=1\ndefaultProfile=0\npadding=13\n"
                      f"colourScheme=2\ndarkTheme=0\n[Profile 0]\nname=Pointer\nshell=/bin/sh\ncommand={command}\n")
    # Only this process tree sees the disposable HTTPS handler. %u is a native
    # desktop-entry argument, never interpolated into a shell command.
    handler = root / "handler.py"
    handler.write_text("#!/usr/bin/python3\nimport json,sys\nfrom pathlib import Path\n"
                       f"with Path({str(root / 'uris')!r}).open('a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n")
    handler.chmod(0o755)
    applications = root / "data/applications"
    applications.mkdir(parents=True)
    (applications / "pointer.desktop").write_text(
        f"[Desktop Entry]\nType=Application\nName=Pointer test\nExec={handler} %u\nMimeType=x-scheme-handler/https;\n")
    (root / "config/mimeapps.list").write_text(
        "[Default Applications]\nx-scheme-handler/https=pointer.desktop;\n")
    env = dict(os.environ, XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"),
               GDK_BACKEND="x11", GTK_A11Y="atspi", G_DEBUG="fatal-warnings")
    artifact_dir = os.environ.get("ZGTK_POINTER_ARTIFACTS")
    if artifact_dir:
        Path(artifact_dir).mkdir(parents=True, exist_ok=True)
    with (root / "stderr").open("w+") as log:
        app = subprocess.Popen([str(Path(sys.argv[1]).resolve())], cwd=root, env=env, stdout=log, stderr=log)
        sequence = 0
        try:
            wait_for(lambda: list(root.glob("*.ready")), "raw PTY")
            first = next(root.glob("*.ready")).stem
            wait_for(lambda: subprocess.run(["xdotool", "search", "--onlyvisible", "--pid", str(app.pid)],
                                            capture_output=True).returncode == 0, "GTK window")
            window = xdo("search", "--onlyvisible", "--pid", app.pid).splitlines()[0]
            xdo("windowfocus", "--sync", window)

            def send(pid, text):
                global sequence
                sequence += 1
                temporary = root / "request"
                temporary.write_text(json.dumps([sequence, text]))
                temporary.replace(root / f"{pid}.control")
                wait_for(lambda: (root / f"{pid}.ack").exists() and
                         (root / f"{pid}.ack").read_text() == str(sequence), "PTY output")
                time.sleep(0.12)

            reset = "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1016l"
            screen = "\x1b[2J\x1b[H" + "Pointer parity: Shift selects; Ctrl opens links\r\n" + \
                "\x1b]8;;https://target.invalid/path?q=a;b\x07https://display.invalid\x1b]8;;\x07\r\n" + \
                "https://plain.invalid/a\r\n" + \
                "\x1b]8;;javascript:alert(1)\x07https://blocked.invalid\x1b]8;;\x07\r\n" + \
                "select this text\r\n"
            send(first, reset + screen)

            def terminals():
                return [n for n in nodes() if n.name == "Terminal" and n.getRoleName() != "frame"
                        and n.queryComponent().getExtents(pyatspi.WINDOW_COORDS).height > 100]

            wait_for(lambda: terminals(), "accessible terminal surface")

            def rect(index=0):
                return sorted(terminals(), key=lambda n: n.queryComponent().getExtents(pyatspi.WINDOW_COORDS).x)[index].queryComponent().getExtents(pyatspi.WINDOW_COORDS)

            scale = int(env.get("GDK_SCALE", "1"))
            # AT-SPI WINDOW_COORDS omit GTK's native shadow inset. Measure the
            # Rasmus background, rather than assuming a window-manager border.
            geometry = root / "geometry.png"
            subprocess.run(["import", "-window", window, str(geometry)], check=True, timeout=5)
            image = Image.open(geometry).convert("RGB")
            origin = next((x, y) for y in range(image.height) for x in range(image.width)
                          if image.getpixel((x, y)) == (26, 26, 25))
            left = origin[0] - scale * rect().x
            top = origin[1] - scale * rect().y

            def move(column, row, index=0):
                r = rect(index)
                # Fixed test profile: Monospace 12 pt has 10 × 19 logical pixels.
                xdo("mousemove", "--sync", "--window", window, left + scale * (r.x + 13 + 10 * column + 4),
                    top + scale * (r.y + 13 + 19 * row + 8))
                time.sleep(0.08)

            def data(pid=first):
                return (root / f"{pid}.input").read_bytes()

            def reports(start, pid=first):
                return re.findall(rb"\x1b\[<(\d+);(\d+);(\d+)([Mm])", data(pid)[start:])

            def capture(name):
                if artifact_dir:
                    subprocess.run(["import", "-window", window, str(Path(artifact_dir) / f"{name}.png")], check=True, timeout=5)

            def underline():
                subprocess.run(["import", "-window", window, str(geometry)], check=True, timeout=5)
                image = Image.open(geometry).convert("RGB")
                r = rect()
                x = left + scale * (r.x + 13)
                y = top + scale * (r.y + 13 + 19 + 17)
                return sum(image.getpixel((p, y)) != (26, 26, 25) for p in range(x, x + scale * 230))

            move(3, 1)
            capture("pointer-default")
            baseline = underline()
            xdo("keydown", "ctrl")
            time.sleep(0.2)
            capture("pointer-ctrl-hover")
            assert underline() > baseline + scale * 150, "Ctrl hover did not underline the link"
            send(first, "\x1b[10;1Hupdated")
            assert underline() == baseline, "Output retained stale hover"
            move(4, 1)
            assert underline() > baseline + scale * 150
            xdo("mousemove", "--window", window, left + 20, top + 20)
            time.sleep(0.1)
            assert underline() == baseline, "Leaving retained stale hover"
            move(3, 1)
            xdo("click", 6)
            assert underline() == baseline, "Scrolling retained stale hover"
            xdo("click", 1)
            wait_for(lambda: (root / "uris").exists(), "native URI handler")
            assert json.loads((root / "uris").read_text().splitlines()[0]) == ["https://target.invalid/path?q=a;b"]
            xdo("keyup", "ctrl")
            move(3, 2)
            xdo("keydown", "ctrl", "click", 1, "keyup", "ctrl")
            wait_for(lambda: len((root / "uris").read_text().splitlines()) == 2, "detected URI handler")
            assert json.loads((root / "uris").read_text().splitlines()[1]) == ["https://plain.invalid/a"]
            move(3, 3)
            xdo("keydown", "ctrl", "click", 1, "keyup", "ctrl")
            time.sleep(0.2)
            assert len((root / "uris").read_text().splitlines()) == 2, "Forbidden OSC8 fell back to visible URL"

            # Press/release, both wheel axes and modifiers reach the real PTY.
            send(first, reset + "\x1b[?1000h\x1b[?1006h")
            move(7, 6)
            start = len(data())
            for button in (1, 2, 3, 4, 5, 6, 7):
                xdo("click", button)
            xdo("keydown", "ctrl", "keydown", "alt", "click", 3, "keyup", "alt", "keyup", "ctrl")
            time.sleep(0.2)
            found = reports(start)
            assert found == [(str(b).encode(), b"8", b"7", suffix) for b, suffix in
                             [(0, b"M"), (0, b"m"), (1, b"M"), (1, b"m"), (2, b"M"), (2, b"m"),
                              (64, b"M"), (65, b"M"), (66, b"M"), (67, b"M"), (26, b"M"), (26, b"m")]], found

            send(first, reset + "\x1b[?1000h")
            start = len(data())
            xdo("click", 1)
            time.sleep(0.1)
            assert data()[start:] == b"\x1b[M" + bytes([32, 40, 39]) + b"\x1b[M" + bytes([35, 40, 39])
            send(first, "\x1b[?1016h")
            start = len(data())
            xdo("click", 3)
            time.sleep(0.1)
            assert reports(start) == [(b"2", b"74", b"122", b"M"), (b"2", b"74", b"122", b"m")], reports(start)
            send(first, reset + "\x1b[?1000h\x1b[?1006h")
            xdo("key", "ctrl+plus")
            time.sleep(0.2)
            r = rect()
            # Pango Monospace 13 pt is 10 × 22 pixels, not the old 10 × 19.
            xdo("mousemove", "--window", window, left + scale * (r.x + 13 + 74), top + scale * (r.y + 13 + 140))
            start = len(data())
            xdo("click", 1)
            time.sleep(0.1)
            assert reports(start) == [(b"0", b"8", b"7", b"M"), (b"0", b"8", b"7", b"m")], reports(start)
            xdo("key", "ctrl+0")
            time.sleep(0.2)

            # Shift is latched to local selection for the complete gesture.
            move(0, 4)
            start = len(data())
            xdo("keydown", "shift", "mousedown", 1)
            move(5, 4)
            xdo("keyup", "shift")
            move(10, 4)
            xdo("mouseup", 1)
            capture("pointer-shift-selection")
            xdo("key", "ctrl+shift+c")
            time.sleep(0.2)
            copied = subprocess.check_output(["xclip", "-selection", "clipboard", "-o"], env=env, text=True)
            assert copied == "select this", repr(copied)
            xdo("keydown", "shift", "click", 4, "click", 6, "keyup", "shift")
            assert not reports(start), reports(start)

            send(first, "\x1b[?1002h")
            move(5, 6)
            start = len(data())
            xdo("mousedown", 1)
            move(9, 7)
            xdo("mouseup", 1)
            move(11, 8)
            assert reports(start) == [(b"0", b"6", b"7", b"M"), (b"32", b"10", b"8", b"M"),
                                      (b"0", b"10", b"8", b"m")], reports(start)
            send(first, "\x1b[?1003h")
            start = len(data())
            move(13, 9)
            assert reports(start) == [(b"35", b"14", b"10", b"M")], reports(start)

            send(first, reset + "\x1b[?1000h\x1b[?1006h")
            move(4, 6)
            start = len(data())
            xdo("mousedown", 1, "mousemove", 2300, 1500, "mouseup", 1)
            time.sleep(0.1)
            assert len(reports(start)) == 2 and reports(start)[1][-1] == b"m", "Outside release was lost"

            # Focus cancellation closes the old pane's press exactly once;
            # physical release after a split must not leak into the new PTY.
            send(first, reset + "\x1b[?1000h\x1b[?1006h")
            move(4, 6)
            start = len(data())
            xdo("mousedown", 1, "key", "ctrl+shift+o")
            wait_for(lambda: len(list(root.glob("*.ready"))) == 2, "split PTY")
            second = next(p.stem for p in root.glob("*.ready") if p.stem != first)
            send(second, reset + screen + "\x1b[?1000h\x1b[?1006h")
            move(4, 6, 1)
            xdo("mouseup", 1)
            time.sleep(0.2)
            assert reports(start) == [(b"0", b"5", b"7", b"M"), (b"0", b"5", b"7", b"m")], reports(start)
            assert not reports(0, second), data(second)
            start = len(data(second))
            xdo("click", 1)
            time.sleep(0.1)
            assert reports(start, second) == [(b"0", b"5", b"7", b"M"), (b"0", b"5", b"7", b"m")]
            capture("pointer-split-routing")

            for shortcut in ("ctrl+alt+Left", "ctrl+shift+Return"):
                move(4, 6, 1)
                before_first, before_second = len(data()), len(data(second))
                xdo("mousedown", 1, "key", shortcut, "mouseup", 1)
                time.sleep(0.2)
                assert reports(before_second, second) == [(b"0", b"5", b"7", b"M"), (b"0", b"5", b"7", b"m")]
                assert not reports(before_first), "Release reached the wrong pane"
                if shortcut == "ctrl+alt+Left":
                    xdo("key", "ctrl+alt+Right")
                else:
                    xdo("key", "ctrl+shift+Return")
                time.sleep(0.2)

            # Transfer the live split tab while a protocol press is outstanding.
            move(4, 6, 1)
            start = len(data(second))
            old_window = window
            xdo("mousedown", 1, "key", "F10")
            time.sleep(0.2)
            xdo("key", "Home", "Down", "Return")
            destination = []

            def transferred():
                result = subprocess.run(["xdotool", "search", "--onlyvisible", "--pid", str(app.pid)],
                                        capture_output=True, text=True)
                destination[:] = [candidate for candidate in result.stdout.splitlines() if candidate != old_window and
                                  subprocess.run(["xdotool", "getwindowname", candidate], capture_output=True,
                                                 text=True).stdout.strip() == "Terminal"]
                return bool(destination)

            wait_for(transferred, "split tab transferred")
            window = destination[0]
            xdo("windowfocus", "--sync", window, "mouseup", 1)
            time.sleep(0.3)
            assert reports(start, second) == [(b"0", b"5", b"7", b"M"), (b"0", b"5", b"7", b"m")], reports(start, second)
            # GTK 4.8 AT-SPI may retain pre-transfer pane origins. Target the
            # centre of the right half via the new native window instead.
            native_size = dict(line.split("=") for line in xdo("getwindowgeometry", "--shell", window).splitlines())
            xdo("mousemove", "--window", window, int(native_size["WIDTH"]) * 3 // 4,
                top + scale * (rect().y + 13 + 19 * 6 + 8))
            capture("pointer-transfer")
            before_first = len(data())
            start = len(data(second))
            xdo("click", 1)
            time.sleep(0.1)
            found = reports(start, second)
            assert len(found) == 2 and found[0][0] == b"0" and found[0][-1] == b"M" and found[1][-1] == b"m", found
            assert not reports(before_first), "Transferred pointer reached the wrong pane"

            # Optional review clip: real native cursor, moving over neighbouring
            # links and controls. Rendering is still GTK, not a browser facsimile.
            if artifact_dir and os.environ.get("ZGTK_POINTER_RECORD"):
                xdo("key", "ctrl+shift+Return")
                send(second, reset + screen)
                geometry_values = dict(line.split("=") for line in xdo("getwindowgeometry", "--shell", window).splitlines())
                width, height = (int(geometry_values[k]) // 2 * 2 for k in ("WIDTH", "HEIGHT"))
                subprocess.run(["import", "-window", window, str(geometry)], check=True, timeout=5)
                image = Image.open(geometry).convert("RGB")
                demo_origin = next((x, y) for y in range(image.height) for x in range(image.width)
                                   if image.getpixel((x, y)) == (26, 26, 25))
                video = Path(artifact_dir) / "pointer-interaction.mp4"
                with (root / "ffmpeg.log").open("w") as video_log:
                    recorder = subprocess.Popen(["ffmpeg", "-y", "-f", "x11grab", "-framerate", "20", "-video_size",
                        f"{width}x{height}", "-i", f"{os.environ['DISPLAY']}+{geometry_values['X']},{geometry_values['Y']}",
                        "-c:v", "libx264", "-preset", "ultrafast", "-crf", "20", "-pix_fmt", "yuv420p", str(video)],
                        stdin=subprocess.PIPE, stdout=video_log, stderr=video_log)
                    try:
                        time.sleep(0.5)

                        def tour(column, row):
                            current = dict(line.split("=") for line in xdo("getmouselocation", "--shell").splitlines())
                            target_x = int(geometry_values["X"]) + demo_origin[0] + scale * (13 + column * 10 + 4)
                            target_y = int(geometry_values["Y"]) + demo_origin[1] + scale * (13 + row * 19 + 8)
                            for step in range(1, 25):
                                xdo("mousemove", round(int(current["X"]) + (target_x - int(current["X"])) * step / 24),
                                    round(int(current["Y"]) + (target_y - int(current["Y"])) * step / 24))
                                time.sleep(0.02)
                            time.sleep(0.3)

                        tour(3, 0)
                        xdo("keydown", "ctrl")
                        tour(3, 3)
                        tour(3, 2)
                        tour(3, 1)
                        time.sleep(0.5)
                        xdo("click", 1, "keyup", "ctrl")
                        tour(0, 4)
                        xdo("keydown", "shift", "mousedown", 1)
                        tour(10, 4)
                        xdo("mouseup", 1, "keyup", "shift")
                        time.sleep(0.5)
                    finally:
                        recorder.stdin.write(b"q\n")
                        recorder.stdin.close()
                        recorder.wait(timeout=10)
                    assert recorder.returncode == 0, (root / "ffmpeg.log").read_text()
            assert app.poll() is None, "GTK application crashed"
            print("Pointer E2E passed: native URI handler/OSC8 policy, all buttons, both wheel axes, modifiers, "
                  "Shift selection, drag/all-motion modes, stale hover, outside release, split/focus/zoom cancellation and per-pane routing")
        finally:
            xdo("mouseup", 1, "keyup", "ctrl", "keyup", "shift", "keyup", "alt")
            if app.poll() is None:
                app.terminate()
            app.wait(timeout=5)
            log.seek(0)
            errors = log.read()
            if errors:
                print(errors, file=sys.stderr)
            assert app.returncode in (0, -15), app.returncode
