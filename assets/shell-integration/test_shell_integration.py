#!/usr/bin/env python3
"""Standalone PTY checks for the bundled zsh integration."""

import fcntl
import os
import pathlib
import pty
import select
import signal
import shlex
import sys
import tempfile
import termios
import time

ROOT = pathlib.Path(__file__).resolve().parent
ZSH = ROOT / "zsh"
HELPER = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
LINUX = sys.argv[2:] == ["--linux"]


def read_until(fd: int, needle: bytes, timeout: float = 5.0) -> bytes:
    data = bytearray()
    deadline = time.monotonic() + timeout
    while needle not in data and time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                data.extend(os.read(fd, 65536))
            except OSError:
                break
    if needle not in data:
        raise AssertionError(f"timed out waiting for {needle!r}: {bytes(data)!r}")
    return bytes(data)


def main(custom_zdotdir: bool = True) -> None:
    with tempfile.TemporaryDirectory() as directory:
        temp = pathlib.Path(directory)
        working_directory = temp / "initial cwd"
        working_directory.mkdir()
        zdot = temp / "config" if custom_zdotdir else temp
        zdot.mkdir(exist_ok=True)
        log = temp / "startup.log"
        for name in (".zshenv", ".zprofile", ".zshrc", ".zlogin"):
            extra = "PS1='VISIBLE> '; PS2='CONT> '" if name == ".zshrc" else ""
            (zdot / name).write_text(f"print -r -- {name} >> {log!s}; {extra}\n")

        fd, slave = pty.openpty()
        pid = os.fork()
        if pid == 0:
            env = os.environ.copy()
            env.update(
                HOME=str(temp),
                TERM="xterm-256color",
                ZIGONAUT_TEST_VALUE="preserved ü",
            )
            env.pop("ZIGONAUT_SHELL_INTEGRATION", None)
            if custom_zdotdir:
                env["ZDOTDIR"] = str(zdot)
            else:
                env.pop("ZDOTDIR", None)
            if HELPER:
                env["COLORTERM"] = "256color"
                if LINUX:
                    os.chdir(working_directory)
                    for standard in range(3):
                        os.dup2(slave, standard)
                    os.close(fd)
                    os.close(slave)
                    env["SHELL"] = "/bin/sh"  # The selected profile takes precedence.
                    os.execve(str(HELPER), [str(HELPER), "--pty-child", "/bin/zsh", "", ""], env)
                os.dup2(slave, 10)
                os.close(fd)
                os.close(slave)
                os.execve(str(HELPER), [str(HELPER), "/bin/zsh", "", str(ROOT)], env)
            # The standalone path needs a controlling terminal too: hooks write
            # C/D markers to /dev/tty, not to redirected command output.
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            os.close(fd)
            for standard in range(3):
                os.dup2(slave, standard)
            os.close(slave)
            env.update(
                ZDOTDIR=str(ZSH),
                ZIGONAUT_ZSH_ORIGINAL_ZDOTDIR=str(zdot),
            )
            os.execve("/bin/zsh", ["zsh", "-l"], env)
        os.close(slave)

        try:
            startup = read_until(fd, b"\x1b]133;B\x07")
            assert b"\x1b]133;A\x07VISIBLE> \x1b]133;B\x07" in startup, repr(startup)
            assert startup.count(b"\x1b]133;A\x07") == 1

            if HELPER and not LINUX:
                os.write(fd, b"print -r -- $COLORTERM\n")
                capability = read_until(fd, b"\x1b]133;B\x07")
                assert b"\x1b]133;C\x07truecolor\r\n" in capability, repr(capability)

            os.write(fd, b'print -r -- "${ZDOTDIR-unset}"; true\n')
            success = read_until(fd, b"\x1b]133;B\x07")
            assert (str(zdot) if custom_zdotdir else "unset").encode() + b"\r\n" in success
            assert b"\x1b]133;C\x07" in success and b"\x1b]133;D;0\x07" in success

            if LINUX:
                os.write(fd, b'printf "%s\\n%s\\n" "$PWD" "$ZIGONAUT_TEST_VALUE"\n')
                inherited = read_until(fd, b"\x1b]133;B\x07")
                assert f"{working_directory}\r\npreserved ü\r\n".encode() in inherited, repr(inherited)

            os.write(fd, b"false\n")
            failed = read_until(fd, b"\x1b]133;B\x07")
            assert b"\x1b]133;D;1\x07" in failed

            encoded_directory = temp / "space ü"
            encoded_directory.mkdir()
            os.write(fd, f"cd {shlex.quote(str(encoded_directory))} && true\n".encode())
            changed = read_until(fd, b"\x1b]133;B\x07")
            assert b"space%20%C3%BC\x07" in changed, repr(changed)

            output = temp / "redirected"
            os.write(fd, f"print payload > {output!s}\n".encode())
            read_until(fd, b"\x1b]133;B\x07")
            assert output.read_bytes() == b"payload\n"

            os.write(fd, f"source {ZSH / 'zigonaut.zsh'}; true\n".encode())
            duplicate = read_until(fd, b"\x1b]133;B\x07")
            assert duplicate.count(b"\x1b]133;C\x07") == 1
            expected_startup = ([".zshenv", ".zshrc"] if LINUX else
                                [".zshenv", ".zprofile", ".zshrc", ".zlogin"])
            assert log.read_text().splitlines() == expected_startup
        finally:
            os.kill(pid, signal.SIGHUP)
            os.close(fd)
            os.waitpid(pid, 0)

    print("zsh shell-integration PTY tests passed")


if __name__ == "__main__":
    main()
    if LINUX:
        main(custom_zdotdir=False)
