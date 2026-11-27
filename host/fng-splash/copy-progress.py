import errno
import fcntl
import os
import pty
import re
import signal
import struct
import subprocess
import sys
import termios
from status import Status, write_status

ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
ROW = re.compile(r'Copying (blob|config) (?:sha256:)?([0-9a-f]{12,64})\b(.*)', re.I)
SIZE = r'(\d+(?:\.\d+)?)\s*([kmgt]?i?b)'
COUNTERS = re.compile(SIZE + r'\s*/\s*' + SIZE, re.I)


def size(value, unit):
    return float(value) * 1024 ** "bkmg".index(unit.lower()[0])


class Progress:
    def __init__(self, verb):
        self.verb = verb
        self.digest = None
        self.current = self.total = 0
        self.unit = "GiB"
        self.complete = self.finishing = False
        self.logged = set()

    def feed(self, line):
        if line.startswith("Writing manifest"):
            self.finishing = True
        row = ROW.fullmatch(line)
        if row:
            kind, digest, rest = row.groups()
            digest = digest[:12]
            counters = COUNTERS.search(rest)
            if counters:
                if kind.lower() != "blob":
                    return None
                a, au, b, bu = counters.groups()
                current, total = size(a, au), size(b, bu)
                if total > self.total and digest != self.digest:
                    self.digest, self.current, self.complete = digest, 0, False
                if digest == self.digest and not self.complete:
                    self.total, self.unit = max(self.total, total), bu
                    self.current = max(self.current, min(current, total))
                    self.complete = self.current >= self.total
                return None  # not log entry
            if kind.lower() == "blob" and digest == self.digest and rest.strip().startswith(("done", "skipped:")):
                self.complete = True
            if re.fullmatch(r'\s*(?:done|skipped: already exists)?\s*\|?\s*', rest):
                key = line.rstrip(" |")
                if key in self.logged:
                    return None
                self.logged.add(key)
                return key
        return line

    def snapshot(self):
        if self.finishing:
            return "Finishing...", -1
        if self.complete:
            return f"{self.verb} remaining data...", -1
        if not self.total:
            return "", -1
        scale = size(1, self.unit)
        return f"{self.verb} {self.current/scale:.1f}/{self.total/scale:.1f} {self.unit}", round(100*self.current/self.total, 1)


def records(raw):
    line = ANSI.sub("", raw.decode("utf-8", "replace")).strip()
    return [s.strip() for s in re.split(r'(?=Copying (?:blob|config) |Writing manifest)', line) if s.strip()]


def run(message, verb, *command):
    def publish(detail, percent):
        status = Status("busy", message, detail, percent)
        write_status(os.environ.get("FNG_SPLASH_STATUS"), status)
        write_status(os.environ.get("FNG_COPY_SHARED_STATUS"), status, shared=True)

    publish("", -1)
    try:
        parent, child = pty.openpty()
    except OSError:
        rc = subprocess.call(command)
        return rc if rc >= 0 else 128 - rc
    try:
        fcntl.ioctl(child, termios.TIOCSWINSZ, struct.pack("HHHH", 100, 180, 0, 0))
        gchild = subprocess.Popen(command, stdout=child, stderr=child, env={**os.environ, "TERM": "xterm"})
    except BaseException:
        os.close(parent)
        raise
    finally:
        os.close(child)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda signum, _: gchild.send_signal(signum))

    progress, pending, last = Progress(verb), b'', ("", -1)
    try:
        while True:
            try:
                chunk = os.read(parent, 65536)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                chunk = b''
            rows = re.split(rb'[\r\n]+', pending + chunk)
            pending = rows.pop() if chunk else b''
            for raw in rows:
                for line in records(raw):
                    if (entry := progress.feed(line)):
                        print(entry, flush=True)
            snapshot = progress.snapshot()
            if snapshot != last:
                publish(*snapshot)
                last = snapshot
            if not chunk:
                break
    finally:
        os.close(parent)
        rc = gchild.wait()
    return rc if rc >= 0 else 128 - rc


if __name__ == "__main__":
    sys.exit(run(*sys.argv[1:]))
