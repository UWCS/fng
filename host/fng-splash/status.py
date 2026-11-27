import codecs
import configparser
from dataclasses import dataclass
import os
import tempfile


@dataclass(frozen=True)
class Status:
    state: str = "busy"
    message: str = "Starting FNG..."
    detail: str = ""
    progress: float = -1


def read_status(path, previous):
    try:
        cfg = configparser.ConfigParser(interpolation=None)
        with path.open(encoding="utf-8") as f:
            cfg.read_file(f)
        s = cfg["splash"]
        state, progress = s.get("state", "busy"), s.getfloat("progress", -1)
        if state in ("busy", "error", "ready") and (progress == -1 or 0 <= progress <= 100):
            return Status(state, s.get("message", previous.message), s.get("detail", ""), progress)
        return previous
    except (OSError, UnicodeError, configparser.Error, KeyError, ValueError):
        return previous


def write_status(path, status, shared=False):
    if not path:
        return
    tmp = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=os.path.dirname(path), delete=False) as f:
            tmp = f.name
            f.write(f"[splash]\nstate={status.state}\nmessage={status.message}\ndetail={status.detail}\nprogress={status.progress:.1f}\n")
        if shared:
            os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except OSError:
        pass  # don't have telemetry break copying
    finally:
        if tmp and os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


class LogTail:
    def __init__(self, path):
        self.file = path.open("rb")
        self.decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

    def read(self):
        return self.decoder.decode(self.file.read(65536)).replace("\x00", "�")  # avoid passing nul to gtk bc i'm kinda scared to find out what happens
