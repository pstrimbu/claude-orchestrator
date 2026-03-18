#!/usr/bin/env python3
"""PTY helper — spawns a command in a real PTY and bridges stdin/stdout.

Usage: pty-helper.py <cols> <rows> <command> [args...]

Stdin  → PTY (child process input)
PTY    → Stdout (child process output)

Resize protocol: write \x1b]orch-resize;<cols>;<rows>\x07 to stdin
to resize the PTY. This is intercepted and not forwarded to the child.
"""
import pty, os, sys, select, signal, struct, fcntl, termios, re

RESIZE_RE = re.compile(rb'\x1b\]orch-resize;(\d+);(\d+)\x07')


def set_winsize(fd, rows, cols):
    winsize = struct.pack('HHHH', rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)


def main():
    if len(sys.argv) < 4:
        print("Usage: pty-helper.py <cols> <rows> <command> [args...]", file=sys.stderr)
        sys.exit(1)

    cols = int(sys.argv[1])
    rows = int(sys.argv[2])
    cmd = sys.argv[3]
    args = sys.argv[3:]

    pid, fd = pty.fork()

    if pid == 0:
        # Child — set terminal size BEFORE exec so the command sees correct dims
        try:
            set_winsize(sys.stdout.fileno(), rows, cols)
        except:
            pass
        os.environ['COLUMNS'] = str(cols)
        os.environ['LINES'] = str(rows)
        os.execvp(cmd, args)
        sys.exit(127)

    # Parent — also set on master fd for good measure
    try:
        set_winsize(fd, rows, cols)
    except:
        pass

    # SIGWINCH is ignored in parent — resize comes via stdin protocol
    signal.signal(signal.SIGWINCH, signal.SIG_IGN)

    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()

    # Set stdout to binary/unbuffered
    sys.stdout = sys.stdout.detach()

    # Buffer for detecting resize sequences that may arrive split across reads
    pending = b''

    try:
        while True:
            rlist = [stdin_fd, fd]
            try:
                r, _, _ = select.select(rlist, [], [], 0.1)
            except (select.error, OSError):
                break

            if stdin_fd in r:
                try:
                    data = os.read(stdin_fd, 4096)
                    if not data:
                        rlist.remove(stdin_fd)
                        continue

                    # Check for resize commands in the data
                    data = pending + data
                    pending = b''

                    while True:
                        m = RESIZE_RE.search(data)
                        if not m:
                            # Check if data ends with a partial resize sequence
                            if data.endswith(b'\x1b') or b'\x1b]orch-resize' in data:
                                # Could be a partial sequence — hold it
                                idx = data.rfind(b'\x1b')
                                if idx >= 0:
                                    pending = data[idx:]
                                    data = data[:idx]
                            break

                        # Found a resize command
                        new_cols = int(m.group(1))
                        new_rows = int(m.group(2))
                        try:
                            set_winsize(fd, new_rows, new_cols)
                            os.kill(pid, signal.SIGWINCH)
                        except:
                            pass

                        # Remove the resize sequence from data
                        data = data[:m.start()] + data[m.end():]

                    # Forward remaining data to child
                    if data:
                        os.write(fd, data)

                except OSError:
                    break

            if fd in r:
                try:
                    data = os.read(fd, 4096)
                    if not data:
                        break
                    os.write(stdout_fd, data)
                except OSError:
                    break
    except KeyboardInterrupt:
        pass
    finally:
        try:
            os.kill(pid, signal.SIGTERM)
        except:
            pass
        try:
            _, status = os.waitpid(pid, 0)
            sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
        except:
            sys.exit(1)


if __name__ == '__main__':
    main()
