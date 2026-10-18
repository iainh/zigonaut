"""Real GTK settings/profile contract via AT-SPI, keyboard input, and POSIX PTYs.

Run in a D-Bus session on X11; requires the distribution's python3-pyatspi.
"""
import configparser
import fcntl
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import termios
import time

import pyatspi


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


def find(role, name, index=0):
    dialog = next((n for n in nodes() if n.getRoleName() == "dialog" and n.name == "Settings"), None)
    return [n for n in nodes(dialog) if n.getRoleName() == role and n.name.startswith(name)][index]


def activate(role, name, index=0):
    assert find(role, name, index).queryAction().doAction(0)
    # GtkButton's accessibility activation completes after its pressed animation.
    time.sleep(0.5)


def edit(name, text, index=0):
    assert find("text", name, index).queryEditableText().setTextContents(text)
    time.sleep(0.1)


def spin(name, value):
    find("spin button", name).queryValue().currentValue = value


def combo(name, index):
    row = find("combo box", name)
    scroller = row.parent
    while scroller.getRoleName() != "scroll pane":
        scroller = scroller.parent
    viewport = scroller.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
    for _ in range(40):
        rect = row.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
        if viewport.y < rect.y + rect.height // 2 < viewport.y + viewport.height:
            break
        xdo("mousemove", "--window", window, viewport.x + viewport.width // 2, viewport.y + viewport.height // 2,
            "click", 4 if rect.y < viewport.y else 5)
        time.sleep(0.1)
    else:
        raise AssertionError(f"Combo row did not scroll into view: {name}")
    xdo("mousemove", "--window", window, rect.x + rect.width // 2, rect.y + rect.height // 2, "click", 1)
    time.sleep(0.2)
    xdo("key", "Home", *(["Down"] * index), "Return")
    time.sleep(0.2)


with tempfile.TemporaryDirectory(prefix="zigonaut-settings-") as directory:
    root = Path(directory)
    config = root / "config" / "zigonaut" / "settings.ini"
    work = root / "work with spaces"
    work.mkdir()
    env = dict(os.environ, XDG_CONFIG_HOME=str(root / "config"), SHELL="/bin/sh",
               PS1="$ ", GTK_A11Y="atspi", GDK_BACKEND="x11")
    executable = str(Path(sys.argv[1]).resolve())
    app = None
    with (root / "stderr").open("w+") as log:
        def start():
            global app
            app = subprocess.Popen([executable], cwd=root, env=env, stdout=log, stderr=log)
            wait_for(lambda: any(n.getRoleName() == "frame" and n.name == "Terminal" for n in nodes()), "terminal window")
            window = xdo("search", "--onlyvisible", "--pid", app.pid).splitlines()[0]
            xdo("windowfocus", "--sync", window)
            return window

        def command(text):
            xdo("type", "--clearmodifiers", "--delay", 1, text)
            xdo("key", "Return")

        def line_ready(name):
            path = root / name
            return path.exists() and path.read_text().endswith("\n")

        def settings():
            xdo("key", "ctrl+comma")
            wait_for(lambda: any(n.getRoleName() == "dialog" and n.name == "Settings" for n in nodes()), "settings dialog")
            time.sleep(0.5)

        def close_settings():
            # Close through the native dialog control rather than killing it.
            dialog = find("dialog", "Settings")
            close = [n for n in nodes(dialog) if n.getRoleName() == "button" and n.name == "Close"]
            assert close[0].queryAction().doAction(0)
            wait_for(lambda: not any(n.getRoleName() == "dialog" and n.name == "Settings" for n in nodes()), "settings closed")

        def saved():
            parser = configparser.ConfigParser(interpolation=None)
            parser.read(config)
            return parser

        def grid(pid):
            fd = os.open(f"/proc/{pid}/fd/0", os.O_RDONLY | os.O_NOCTTY)
            try:
                return struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, bytes(8)))[:2]
            finally:
                os.close(fd)

        def stop(window):
            xdo("windowfocus", window)
            # All sessions in this test respond to SIGHUP.
            while app.poll() is None:
                xdo("key", "ctrl+shift+w")
                time.sleep(0.3)
            assert app.wait(timeout=8) == 0
            wait_for(lambda: not any(n.getRoleName() == "application" and n.name == "zigonaut" for n in nodes()), "application cleanup")

        try:
            window = start()
            command("echo $$ > original.pid; stty size > before")
            wait_for(lambda: line_ready("before"), "initial shell")
            original = (root / "original.pid").read_text().strip()
            xdo("key", "ctrl+shift+o")
            time.sleep(0.3)
            command("echo $$ > pane.pid; stty size > pane-before")
            wait_for(lambda: line_ready("pane-before"), "split terminal")
            pane = (root / "pane.pid").read_text().strip()
            xdo("key", "ctrl+alt+Left")
            xdo("key", "ctrl+shift+t")
            time.sleep(0.3)
            command("echo $$ > second.pid")
            wait_for(lambda: line_ready("second.pid"), "second existing terminal")
            second = (root / "second.pid").read_text().strip()
            xdo("key", "ctrl+Page_Up")
            settings()
            assert not config.exists(), "Opening preferences should not write a file"
            assert not any(n.getRoleName() == "button" and n.name == "Apply" for n in nodes())
            spin("Font size", 16)
            wait_for(lambda: config.exists() and saved()["Settings"]["fontSize"] == "16", "automatic font persistence")
            wait_for(lambda: grid(original)[0] < 24 and grid(pane)[0] < 24, "live resize while preferences remain open")
            spin("Line height", 125)
            spin("Terminal padding", 20)
            combo("Colour scheme", 2)
            assert saved()["Settings"]["fontSize"] == "16"
            assert config.stat().st_mode & 0o777 == 0o600
            activate("page tab", "Terminal")
            spin("Scrollback lines", 37)
            spin("Initial columns", 93)
            spin("Initial rows", 19)
            spin("Clipboard write limit", 3)
            activate("check box", "Allow terminal clipboard writes")
            assert saved()["Settings"]["terminalClipboardWrites"] == "1"
            activate("page tab", "Profiles")
            activate("button", "Add Profile")
            activate("button", "Add Profile")
            assert saved()["Settings"]["profileCount"] == "3"
            assert saved()["Profile 1"]["name"] != saved()["Profile 2"]["name"]
            activate("button", "Remove profile", 2)
            edit("Name", "Build shell", 1)
            edit("Shell executable", "/bin/sh", 1)
            edit("Command", "printf '%s' \"$PWD\" > profile.cwd; echo $$ >> launches; exec /bin/sh -i", 1)
            edit("Working directory", str(work), 1)
            combo("Default profile", 1)
            # Renaming must preserve the selected profile, not reset it to 0.
            edit("Name", "Builder", 1)
            assert saved()["Settings"]["defaultProfile"] == "1"
            assert saved()["Profile 1"]["name"] == "Builder"
            valid = config.read_bytes()
            edit("Name", "DEFAULT", 1)
            assert config.read_bytes() == valid, "Duplicate names were persisted"
            assert any(n.name == "Changes not saved; previous settings remain active" for n in nodes())
            edit("Name", "Builder", 1)
            edit("Shell executable", "/missing-shell", 1)
            assert config.read_bytes() == valid, "Invalid shell was persisted"
            edit("Shell executable", "/bin/sh", 1)
            # Delete a profile before the default and retain its identity.
            activate("button", "Remove profile", 0)
            assert saved()["Settings"]["defaultProfile"] == "0"
            assert saved()["Profile 0"]["name"] == "Builder"
            activate("button", "Remove profile", 0)
            assert saved()["Settings"]["profileCount"] == "1"
            # Keep an alternate interactive profile for explicit menu launches.
            activate("button", "Add Profile")
            edit("Name", "Interactive", 1)
            # A failed disk save must leave both the saved and live settings intact.
            backup = config.parent.with_name("backup")
            config.parent.rename(backup)
            config.parent.write_text("blocked settings directory")
            edit("Name", "Cannot save", 1)
            assert b"Cannot save" not in (backup / "settings.ini").read_bytes()
            config.parent.unlink()
            backup.rename(config.parent)
            close_settings()
            xdo("windowfocus", window)
            command("echo $$ > retained.pid; stty size > after")
            wait_for(lambda: line_ready("after"), "live terminal settings")
            assert (root / "retained.pid").read_text().strip() == original
            before = tuple(map(int, (root / "before").read_text().split()))
            after = tuple(map(int, (root / "after").read_text().split()))
            assert before == (24, 80), before
            assert after[0] < before[0] and after[1] < before[1], (before, after)
            xdo("key", "ctrl+alt+Right")
            command("echo $$ > pane-retained.pid; stty size > pane-after")
            wait_for(lambda: line_ready("pane-after"), "settings on an unfocused pane")
            assert (root / "pane-retained.pid").read_text().strip() == pane
            pane_before = tuple(map(int, (root / "pane-before").read_text().split()))
            pane_after = tuple(map(int, (root / "pane-after").read_text().split()))
            assert all(a < b for a, b in zip(pane_after, pane_before)), (pane_before, pane_after)
            assert pane_after[0] == after[0] and abs(pane_after[1] - after[1]) <= 1, (after, pane_after)
            xdo("key", "ctrl+alt+Left", "ctrl+shift+e")
            time.sleep(0.3)
            command("pwd > inherited-profile.cwd")
            wait_for(lambda: line_ready("inherited-profile.cwd"), "split retains its deleted launch profile")
            assert (root / "inherited-profile.cwd").read_text().strip() == str(root)
            xdo("key", "ctrl+shift+w")
            xdo("key", "ctrl+Page_Down")
            command("echo $$ > second-retained.pid; stty size > second-after")
            wait_for(lambda: line_ready("second-after"), "settings on the inactive terminal")
            assert (root / "second-retained.pid").read_text().strip() == second
            second_after = tuple(map(int, (root / "second-after").read_text().split()))
            assert all(a < b for a, b in zip(second_after, before)), (before, second_after)
            xdo("key", "ctrl+Page_Up")
            # A shell-created file can precede GTK consuming the PTY output.
            # The following title marker confirms GTK processed each OSC write.
            command(r"printf '\033]52;c;b25l\007\033]2;clipboard-ready\007'")
            wait_for(lambda: xdo("getwindowname", window) == "clipboard-ready", "terminal clipboard write")
            assert subprocess.check_output(["xclip", "-selection", "clipboard", "-o"], text=True) == "one"
            command(r"printf '\033]52;c;Zm91cg==\007\033]2;clipboard-limit\007'")
            wait_for(lambda: xdo("getwindowname", window) == "clipboard-limit", "over-limit clipboard write")
            assert subprocess.check_output(["xclip", "-selection", "clipboard", "-o"], text=True) == "one"
            xdo("key", "ctrl+shift+t")
            wait_for(lambda: (work / "profile.cwd").exists(), "default profile launch")
            assert (work / "profile.cwd").read_text() == str(work)
            first_launch = (work / "launches").read_text().strip()
            assert first_launch != original
            # Navigate the actual profile submenu to select Interactive.
            xdo("key", "F10")
            time.sleep(0.3)
            xdo("key", "Down", "Down", "Down", "Right")
            time.sleep(0.3)
            xdo("key", "Down", "Down", "Return")
            time.sleep(0.5)
            command("pwd > alternate.cwd")
            wait_for(lambda: line_ready("alternate.cwd"), "named profile menu launch")
            assert (root / "alternate.cwd").read_text().strip() == str(root)
            xdo("key", "ctrl+shift+o")
            time.sleep(0.3)
            command("pwd > alternate-split.cwd")
            wait_for(lambda: line_ready("alternate-split.cwd"), "named profile inherited by split")
            assert (root / "alternate-split.cwd").read_text().strip() == str(root)
            assert len((work / "launches").read_text().splitlines()) == 1
            stop(window)
            window = start()
            wait_for(lambda: len((work / "launches").read_text().splitlines()) == 2, "persisted default profile at restart")
            command("stty size > restarted-grid")
            wait_for(lambda: (work / "restarted-grid").exists() and (work / "restarted-grid").stat().st_size > 0, "persisted initial grid")
            restarted_grid = tuple(map(int, (work / "restarted-grid").read_text().split()))
            assert restarted_grid == (19, 93), restarted_grid
            settings()
            assert find("spin button", "Font size").queryValue().currentValue == 16
            activate("page tab", "Profiles")
            assert saved()["Profile 0"]["name"] == "Builder"
            edit("Name", "Renamed automatically")
            close_settings()
            settings()
            activate("page tab", "Profiles")
            assert saved()["Profile 0"]["name"] == "Renamed automatically"
            assert find("label", "Renamed automatically"), "Reopened default-profile selector lost the saved name"
            edit("Shell executable", "/incomplete")
            close_settings()
            assert saved()["Profile 0"]["shell"] == "/bin/sh", "Closing persisted an invalid edit"
            stop(window)
            # Corruption falls back without destroying the file.
            config.write_text("[Settings]\nversion=99\n")
            window = start()
            assert config.read_text() == "[Settings]\nversion=99\n"
            stop(window)
            print(f"Settings E2E passed: automatic save without Apply, live PTY resize {before} → {after} without shell restart, "
                  "settings across split panes and inactive tabs, inherited launch-profile snapshots, "
                  "private atomic persistence, validation, add/rename/remove/default profiles, named menu launch, "
                  "command and directory with spaces, restart, valid edits retained on close, invalid edits rejected, and corrupt-file preservation")
        finally:
            if app and app.poll() is None:
                app.terminate()
                app.wait(timeout=5)
            log.seek(0)
            errors = log.read()
            if errors:
                print(errors, file=sys.stderr)
