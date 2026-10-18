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
    env = dict(os.environ, SHELL="/bin/sh", PS1="$ ", GDK_BACKEND="x11",
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
            xdo("key", "ctrl+shift+f")
            time.sleep(0.3)
            source_window = window
            window = move_to_window("First session")
            xdo("key", "Escape")
            command('printf "%s %s" "$$" "$transfer_marker" > transferred')
            assert contents("transferred") == f"{first} preserved"
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
            xdo("key", "ctrl+shift+w")
            assert app.wait(timeout=8) == 0
            wait_for(lambda: not alive(second), "SIGHUP-resistant shell reaped after last window closes")
            print(f"GTK E2E passed: two isolated shells, titles, focus, tab reordering, resize {before} → {after}, "
                  "Ctrl+C, prompt shortcuts without PTY leakage, UTF-8 clipboard paste, per-tab search and focus restoration, "
                  "live tab transfers (including an open search and last tab), "
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
