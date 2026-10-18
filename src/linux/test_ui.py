"""Exercise the real GTK application and PTYs on X11 (or xvfb-run)."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def xdo(*args):
    return subprocess.check_output(["xdotool", *map(str, args)], text=True).strip()


def wait_for(predicate, description):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(f"Timed out: {description}")


def alive(pid):
    return Path(f"/proc/{pid}").exists()


with tempfile.TemporaryDirectory(prefix="zigonaut-gtk-") as directory:
    root = Path(directory)
    env = dict(os.environ, SHELL="/bin/sh", PS1="$ ", GDK_BACKEND="x11", XDG_CONFIG_HOME=str(root / "config"),
               GTK_A11Y="none", G_DEBUG="fatal-warnings")
    with (root / "stderr").open("w+") as log:
        # A desktop launcher or build runner may ignore SIGINT. The terminal
        # must restore normal child signals regardless of its own disposition.
        previous_sigint = signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            app = subprocess.Popen([str(Path(sys.argv[1]).resolve())], cwd=root,
                                   env=env, stdout=log, stderr=log)
        finally:
            signal.signal(signal.SIGINT, previous_sigint)
        children = []
        clipboard = None
        try:
            window = []

            def find_window():
                result = subprocess.run(
                    ["xdotool", "search", "--onlyvisible", "--pid", str(app.pid)],
                    text=True, capture_output=True)
                if result.returncode == 0:
                    window[:] = result.stdout.splitlines()[:1]
                return bool(window)

            wait_for(find_window, "GTK window")
            window = window[0]
            xdo("windowfocus", "--sync", window)
            wait_for(lambda: xdo("getwindowname", window) == "Terminal", "initial window title")

            def command(text):
                xdo("type", "--clearmodifiers", "--delay", 1, text)
                xdo("key", "Return")

            def contents(name):
                path = root / name
                wait_for(lambda: path.exists() and path.stat().st_size > 0, name)
                return path.read_text().strip()

            def move_to_window(title):
                destination = []
                xdo("key", "F10")
                time.sleep(0.1)
                xdo("key", "Home", "Down", "Return")

                def find_destination():
                    result = subprocess.run(
                        ["xdotool", "search", "--onlyvisible", "--pid", str(app.pid)],
                        text=True, capture_output=True)
                    destination[:] = [candidate for candidate in result.stdout.splitlines()
                                      if candidate != window and xdo("getwindowname", candidate) == title]
                    return bool(destination)

                wait_for(find_destination, "tab transferred to a new window")
                xdo("windowfocus", "--sync", destination[0])
                return destination[0]

            command(r"echo $$ > first.pid; stty size > before; printf '\033]2;First session\007'")
            first = int(contents("first.pid"))
            children.append(first)
            before = tuple(map(int, contents("before").split()))
            wait_for(lambda: xdo("getwindowname", window) == "First session", "OSC title")
            assert before[0] > 10 and before[1] > 40, before
            xdo("key", "ctrl+shift+t")
            time.sleep(0.2)
            command(r"echo $$ > second.pid; printf '\033]2;Second session\007'")
            second = int(contents("second.pid"))
            children.append(second)
            assert first != second and alive(first)
            xdo("key", "ctrl+Page_Up")
            time.sleep(0.2)
            command("echo first > focused")
            assert contents("focused") == "first"
            wait_for(lambda: xdo("getwindowname", window) == "First session", "tab title restored")
            xdo("key", "ctrl+Page_Down")
            wait_for(lambda: xdo("getwindowname", window) == "Second session", "next tab")
            xdo("key", "ctrl+shift+Page_Up")
            xdo("key", "ctrl+Page_Down")
            wait_for(lambda: xdo("getwindowname", window) == "First session", "tab reordered without losing selection or sessions")
            xdo("key", "ctrl+shift+f")
            time.sleep(0.3)
            command("echo leaked > search-leaked")
            xdo("key", "ctrl+a")
            xdo("type", "First")
            time.sleep(0.3)
            xdo("key", "Return", "shift+Return")
            xdo("key", "ctrl+Page_Up")
            wait_for(lambda: xdo("getwindowname", window) == "Second session", "switch away from search")
            command("echo second > search-other-tab")
            assert contents("search-other-tab") == "second"
            xdo("key", "ctrl+Page_Down")
            wait_for(lambda: xdo("getwindowname", window) == "First session", "return to searching tab")
            xdo("key", "ctrl+a")
            command("echo leaked > search-leaked")
            xdo("key", "Escape")
            command("echo restored > search-focus")
            assert contents("search-focus") == "restored"
            assert not (root / "search-leaked").exists(), "Search input reached a shell"
            xdo("windowsize", "--sync", window, 720, 480)
            time.sleep(0.3)
            command("stty size > after")
            after = tuple(map(int, contents("after").split()))
            assert after[0] < before[0] and after[1] < before[1], (before, after)
            command("sleep 30")
            time.sleep(0.2)
            xdo("key", "ctrl+c")
            command("echo interrupted > interrupt")
            assert contents("interrupt") == "interrupted"
            command(r"stty -echo -icanon; printf '\033[>2u'; echo ready > prompt-input-ready; dd bs=1 count=1 of=prompt-key 2>/dev/null; printf '\033[<u'; stty sane; echo done > prompt-input-done")
            assert contents("prompt-input-ready") == "ready"
            xdo("key", "ctrl+shift+Up", "ctrl+shift+Down", "z")
            assert contents("prompt-input-done") == "done"
            assert contents("prompt-key") == "z", "Prompt shortcuts leaked key events into the PTY"
            clipboard = subprocess.Popen(
                ["xclip", "-selection", "clipboard", "-in", "-quiet", "-loops", "1"],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            clipboard.stdin.write("printf 'café 界' > pasted".encode())
            clipboard.stdin.close()
            time.sleep(0.2)
            xdo("key", "ctrl+shift+v")
            time.sleep(0.2)
            xdo("key", "Return")
            assert contents("pasted") == "café 界"
            command("transfer_marker=preserved")
            # Nested splits keep independent shells and route actions to the
            # focused leaf, not to the original tab's terminal.
            xdo("windowsize", "--sync", window, 980, 640)
            xdo("key", "ctrl+shift+o")
            time.sleep(0.3)
            command(r"echo $$ > right.pid; pane=right; stty size > right-size; printf '\033]2;Right pane\007'")
            right = int(contents("right.pid"))
            children.append(right)
            assert right not in (first, second)
            right_size = tuple(map(int, contents("right-size").split()))
            xdo("key", "ctrl+shift+f")
            time.sleep(0.3)
            xdo("type", "Right")
            xdo("key", "ctrl+shift+e")
            time.sleep(0.3)
            command(r"echo $$ > bottom.pid; pane=bottom; stty size > bottom-size; printf '\033]2;Bottom pane\007'")
            bottom = int(contents("bottom.pid"))
            children.append(bottom)
            assert bottom not in (first, second, right)
            bottom_size = tuple(map(int, contents("bottom-size").split()))
            assert bottom_size[0] < right_size[0] and abs(bottom_size[1] - right_size[1]) <= 1, (right_size, bottom_size)
            xdo("key", "ctrl+alt+Up")
            wait_for(lambda: xdo("getwindowname", window) == "Right pane", "directional focus up")
            command("echo leaked > pane-search-leaked")
            xdo("key", "Escape")
            assert not (root / "pane-search-leaked").exists(), "Per-pane search focus was lost"
            command('echo "$pane" > up-focus')
            assert contents("up-focus") == "right"
            xdo("key", "ctrl+alt+Left")
            wait_for(lambda: xdo("getwindowname", window) == "First session", "directional focus left")
            xdo("key", "ctrl+alt+Page_Up")
            wait_for(lambda: xdo("getwindowname", window) == "Bottom pane", "pane cycle wraps backwards")
            xdo("key", "ctrl+alt+shift+Up")
            time.sleep(0.3)
            command("stty size > pane-resized")
            resized = tuple(map(int, contents("pane-resized").split()))
            assert resized[0] > bottom_size[0] and resized[1] == bottom_size[1], (bottom_size, resized)
            xdo("key", "ctrl+alt+equal")
            time.sleep(0.3)
            command("stty size > pane-equalized")
            equalized = tuple(map(int, contents("pane-equalized").split()))
            assert abs(equalized[0] - bottom_size[0]) <= 1, (bottom_size, equalized)
            xdo("windowsize", "--sync", window, 1080, 720)
            time.sleep(0.3)
            command("stty size > pane-window-larger")
            larger = tuple(map(int, contents("pane-window-larger").split()))
            assert larger[0] > equalized[0] and larger[1] > equalized[1], (equalized, larger)
            xdo("windowsize", "--sync", window, 980, 640)
            time.sleep(0.3)
            command("stty size > pane-window-restored")
            restored = tuple(map(int, contents("pane-window-restored").split()))
            assert all(abs(a - b) <= 1 for a, b in zip(equalized, restored)), (equalized, restored)
            clipboard.wait(timeout=3)
            clipboard = subprocess.Popen(
                ["xclip", "-selection", "clipboard", "-in", "-quiet", "-loops", "1"],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            clipboard.stdin.write('printf "%s café" "$pane" > pane-pasted'.encode())
            clipboard.stdin.close()
            time.sleep(0.2)
            xdo("key", "ctrl+shift+v")
            time.sleep(0.2)
            xdo("key", "Return")
            assert contents("pane-pasted") == "bottom café"
            command("(sleep 0.3; echo live > hidden-output) &")
            xdo("key", "ctrl+shift+Return")
            time.sleep(0.3)
            command("stty size > pane-zoomed")
            zoomed = tuple(map(int, contents("pane-zoomed").split()))
            assert zoomed[0] > equalized[0] and zoomed[1] > equalized[1], (equalized, zoomed)
            xdo("key", "ctrl+alt+Page_Down")
            wait_for(lambda: xdo("getwindowname", window) == "First session", "zoom follows pane focus")
            assert contents("hidden-output") == "live", "Zoom stopped a hidden PTY"
            xdo("key", "ctrl+shift+Return")
            # Raw Kitty input distinguishes swallowed releases from ordinary
            # terminal input even when focus moves to another pane and back.
            command(r"stty -echo -icanon; printf '\033[>2u'; echo ready > pane-input-ready; dd bs=1 count=1 of=pane-key 2>/dev/null; printf '\033[<u'; stty sane; echo done > pane-input-done")
            assert contents("pane-input-ready") == "ready"
            xdo("key", "ctrl+alt+Page_Down", "ctrl+alt+Page_Up",
                "ctrl+shift+Return", "ctrl+shift+Return", "ctrl+alt+shift+Right", "ctrl+alt+equal", "z")
            assert contents("pane-input-done") == "done"
            assert contents("pane-key") == "z", "Pane shortcuts leaked key events into the PTY"
            xdo("key", "ctrl+shift+f")
            time.sleep(0.3)
            source_window = window
            window = move_to_window("First session")
            xdo("key", "Escape")
            command('printf "%s %s" "$$" "$transfer_marker" > transferred')
            assert contents("transferred") == f"{first} preserved"
            xdo("key", "ctrl+alt+Page_Down")
            wait_for(lambda: xdo("getwindowname", window) == "Right pane", "split tab transfer preserves focused title")
            command('printf "%s %s" "$$" "$pane" > right-transferred')
            assert contents("right-transferred") == f"{right} right"
            xdo("key", "ctrl+alt+Down")
            wait_for(lambda: xdo("getwindowname", window) == "Bottom pane", "nested pane survives transfer")
            command('printf "%s %s" "$$" "$pane" > bottom-transferred')
            assert contents("bottom-transferred") == f"{bottom} bottom"
            command("exit")
            wait_for(lambda: not alive(bottom), "nested pane shell exit reaped")
            wait_for(lambda: xdo("getwindowname", window) == "Shell exited", "exited pane retained")
            xdo("key", "ctrl+shift+Return")
            xdo("key", "ctrl+shift+w")
            wait_for(lambda: xdo("getwindowname", window) == "Right pane", "closing nested pane collapses split and focuses neighbour")
            assert alive(first) and alive(right) and alive(second)
            xdo("key", "ctrl+shift+w")
            wait_for(lambda: not alive(right), "closed pane shell reaped")
            wait_for(lambda: xdo("getwindowname", window) == "First session", "closing second pane restores final pane")
            xdo("key", "ctrl+shift+w")
            wait_for(lambda: not alive(first), "closed tab's shell reaped")
            assert alive(second), "Closing one tab killed another session"
            window = source_window
            xdo("windowfocus", "--sync", window)
            xdo("key", "ctrl+shift+t")
            time.sleep(0.2)
            command("echo $$ > exited.pid; exit")
            exited = int(contents("exited.pid"))
            children.append(exited)
            wait_for(lambda: not alive(exited), "normal shell exit reaped")
            wait_for(lambda: xdo("getwindowname", window) == "Shell exited", "final shell output retained")
            assert app.poll() is None
            xdo("key", "ctrl+shift+w")
            window = move_to_window("Second session")
            command("trap '' HUP; echo ready > stubborn")
            assert contents("stubborn") == "ready"
            xdo("key", "ctrl+shift+o")
            time.sleep(0.3)
            command("trap '' HUP; echo $$ > last-pane.pid")
            last_pane = int(contents("last-pane.pid"))
            children.append(last_pane)
            xdo("key", "F10")
            time.sleep(0.1)
            xdo("key", *(["Down"] * 5), "Return")  # Panes submenu.
            time.sleep(0.1)
            xdo("key", *(["Down"] * 8), "Return")  # Back row, then Close Tab.
            assert app.wait(timeout=8) == 0
            wait_for(lambda: not alive(second), "SIGHUP-resistant shell reaped after last window closes")
            wait_for(lambda: not alive(last_pane), "whole-tab close reaps every pane")
            print(f"GTK E2E passed: two isolated shells, titles, focus, tab reordering, resize {before} → {after}, "
                  "Ctrl+C, prompt shortcuts without PTY leakage, UTF-8 clipboard paste, per-tab search and focus restoration, "
                  f"nested independent panes, directional/cyclic focus, pane resize {bottom_size} → {resized}, "
                  f"equalize and zoom {equalized} → {zoomed}, hidden PTY output, pane shortcuts without leakage, "
                  "live split-tab transfers (including an open search and last tab), pane exit and collapse, "
                  "shell exit, tab close, and bounded child cleanup")
        finally:
            if clipboard and clipboard.poll() is None:
                clipboard.terminate()
                clipboard.wait(timeout=3)
            if app.poll() is None:
                app.terminate()
                app.wait(timeout=3)
            for child in children:
                if alive(child):
                    os.kill(child, 9)
            log.seek(0)
            errors = log.read()
            if errors:
                print(errors, file=sys.stderr)
