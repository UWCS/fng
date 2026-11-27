# gtk3 session splash on host
import argparse
import configparser
import os
from pathlib import Path
import sys
import time

os.environ["GDK_BACKEND"] = "x11"

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_foreign("cairo")
from gi.repository import Gdk, GLib, Gtk
import cairo

from animations import Spinner
from background import Aurora
from fancy_progress import paint as paint_progress
from status import LogTail, Status, read_status
DEFAULT = Path(__file__).resolve().parent / "themes/fng"


class Splash:
    def __init__(self, args):
        self.args = args
        self.theme = configparser.ConfigParser(interpolation=None)
        with (args.theme / "theme.ini").open(encoding="utf-8") as f:
            self.theme.read_file(f)
        self.status = Status()
        self.tail = LogTail(args.log_file)
        self.started = time.monotonic()
        self.verbose = False
        self.exit_code = 0
        self.load_layout()
        self.configure_animation()
        self.configure_background()
        self.configure_progress()
        self.title.set_text(self.theme["branding"]["title"])
        self.subtitle.set_text(self.theme["branding"]["subtitle"])
        self.footer.set_markup(self.theme["footer"]["text"])
        buf = self.log_view.get_buffer()
        self.tail_mark = buf.create_mark(None, buf.get_end_iter(), False)
        self.connect_events()
        self.show()

    def load_layout(self):
        builder = Gtk.Builder()
        builder.add_from_file(str(self.args.theme / "layout.ui"))
        for name in ("window", "stack", "animation", "title", "subtitle", "message", "detail", "progress", "log_view", "log_status", "follow", "hint", "dismiss", "background", "footer"):
            obj = builder.get_object(name)
            if obj is None:
                raise ValueError(f"theme layout is missing widget {name!r}")
            setattr(self, name, obj)
        css = Gtk.CssProvider()
        css.load_from_path(str(self.args.theme / "style.css"))
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def configure_animation(self):
        a = self.theme["animation"]
        points = [(float(x), float(y), self.rgba(colour))
                  for x, y, colour in (spec.split() for spec in a["points"].split(";") if spec.strip())]
        self.spinner = Spinner(points, list(map(int, a["ring_order"].split())),
                               **{key: a.getfloat(key) for key in (
                                   "duration", "radius", "spacing", "intro_hold", "intro_morph",
                                   "speed_min", "speed_max", "speed_change_min_s", "speed_change_max_s", "dot_scale_wobble")})
        self.fps = self.theme["rendering"].getint("fps")
        if self.fps <= 0:
            raise ValueError("rendering.fps must be positive")

    def configure_background(self):
        b = self.theme["background"]
        self.aurora = Aurora(cairo, base=self.rgba(b["base_colour"]),
            hotspots=[self.rgba(c.strip()) for c in b["hotspots"].split(",") if c.strip()],
            speed=b.getfloat("speed"), wave_strength=b.getfloat("wave_strength"),
            vignette=b.getboolean("vignette"), fps=b.getint("fps"), resolution=b.getint("resolution"))
        self.background.connect("draw", self.draw_background)

    def configure_progress(self):
        p = self.theme["progress"]
        self.progress_options = {key: p.getfloat(key) for key in ("corner_radius", "gradient_speed", "segment", "period")}
        if p.getfloat("period") <= 0 or not 0 < p.getfloat("segment") <= 1:
            raise ValueError("invalid progress period or segment")
        self.progress_options.update(track=self.rgba(p["track_colour"]), pulse=p.getboolean("pulse"), wave=p.getboolean("wave"))
        self.progress.connect("draw", self.draw_progress)

    def connect_events(self):
        self.window.connect("delete-event", self.close)
        self.window.connect("destroy", lambda *_: Gtk.main_quit())
        self.window.connect("key-press-event", self.keypress)
        self.dismiss.connect("clicked", self.close)
        self.follow.connect("toggled", lambda *_: self.scroll_to_end() if self.follow.get_active() else None)
        self.animation.connect("draw", self.draw)
        Gtk.Settings.get_default().connect("notify::gtk-enable-animations", lambda *_: self.redraw())

    def show(self):
        if self.args.fullscreen:
            self.configure_fullscreen()
        self.window.show_all()
        for widget in (self.title, self.subtitle, self.footer):
            widget.set_visible(bool(widget.get_text()))
        self.stack.set_visible_child_name("splash")
        self.apply_status()
        GLib.timeout_add(200, self.poll)
        self.window.add_tick_callback(self.tick)
        if self.args.fullscreen:
            GLib.idle_add(self.focus_fullscreen)

    @staticmethod
    def rgba(value):
        colour = Gdk.RGBA()
        if not colour.parse(value):
            raise ValueError(f"invalid theme colour: {value}")
        return colour.red, colour.green, colour.blue, colour.alpha

    def configure_fullscreen(self):
        self.window.set_decorated(False)
        self.window.set_resizable(False)
        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        rect = monitor.get_geometry()
        self.window.set_default_size(rect.width, rect.height)
        self.window.realize()
        gwin = self.window.get_window()
        gwin.set_override_redirect(True)
        self.window.move(rect.x, rect.y)
        self.window.resize(rect.width, rect.height)
        gwin.move_resize(rect.x, rect.y, rect.width, rect.height)

    def focus_fullscreen(self):
        gwin = self.window.get_window()
        gwin.raise_()
        gwin.focus(Gdk.CURRENT_TIME)
        return GLib.SOURCE_REMOVE

    def keypress(self, _widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.verbose = not self.verbose
            self.stack.set_visible_child_name("verbose" if self.verbose else "splash")
            self.update_hint()
            self.redraw()
            if self.verbose and self.follow.get_active():
                self.scroll_to_end()
            return True
        return False

    def update_hint(self):
        self.hint.set_text(self.theme["diagnostics"]["verbose_hint" if self.verbose else "hint"])
        if self.args.fullscreen:
            hide = not self.verbose and self.status.state != "error"
            cursor = Gdk.Cursor.new_for_display(Gdk.Display.get_default(), Gdk.CursorType.BLANK_CURSOR) if hide else None
            self.window.get_window().set_cursor(cursor)

    def motion_enabled(self):
        return Gtk.Settings.get_default().get_property("gtk-enable-animations")

    def draw(self, widget, cr):
        animated = self.status.state == "busy" and self.motion_enabled()
        self.spinner.draw(cr, widget.get_allocated_width(), widget.get_allocated_height(), widget.get_frame_clock().get_frame_time() / 1e6 - self.started, animated)
        return False

    def redraw(self):
        for widget in (self.animation, self.progress, self.background):
            widget.queue_draw()

    def draw_background(self, widget, cr):
        animated = self.motion_enabled() and self.status.state == "busy" and not self.verbose
        self.aurora.paint(cr, widget.get_allocated_width(), widget.get_allocated_height(), widget.get_frame_clock().get_frame_time() / 1e6 - self.started, animated)
        return True

    def draw_progress(self, widget, cr):
        paint_progress(cairo, cr, widget.get_allocated_width(), widget.get_allocated_height(), self.status.progress, widget.get_frame_clock().get_frame_time() / 1e6 - self.started,
                       animated=self.motion_enabled(), **self.progress_options)
        return True

    def tick(self, widget, frame_clock):
        if not self.verbose and self.status.state == "busy" and self.motion_enabled():
            self.animation.queue_draw()
            self.progress.queue_draw()
            if self.aurora.needs_frame(widget.get_frame_clock().get_frame_time() / 1e6 - self.started):
                self.background.queue_draw()
        return GLib.SOURCE_CONTINUE

    def apply_status(self):
        s = self.status
        self.message.set_text(s.message)
        self.log_status.set_text(s.message + (" - " + s.detail if s.detail else ""))
        self.detail.set_text(s.detail or " ")
        # reserve line at start
        self.detail.set_visible(s.state == "busy" or bool(s.detail))
        self.progress.set_visible(s.state == "busy")
        self.dismiss.set_visible(s.state == "error")
        self.redraw()
        self.update_hint()

    def scroll_to_end(self):
        if self.verbose:
            self.log_view.scroll_mark_onscreen(self.tail_mark)

    def append_log(self, text):
        if not text:
            return
        buf = self.log_view.get_buffer()
        buf.insert(buf.get_end_iter(), text)
        excess = buf.get_char_count() - 100000
        if excess > 0:
            buf.delete(buf.get_start_iter(), buf.get_iter_at_offset(excess))
        if self.follow.get_active():
            self.scroll_to_end()

    def poll(self):
        self.append_log(self.tail.read())
        status = read_status(self.args.status_file, self.status)
        if status.state == "ready":
            self.window.destroy()
            return GLib.SOURCE_REMOVE
        if status != self.status:
            self.status = status
            self.apply_status()
        return GLib.SOURCE_CONTINUE

    def close(self, *_):
        self.exit_code = int(self.status.state == "error")
        self.window.destroy()
        return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--theme", type=Path, default=DEFAULT)
    parser.add_argument("--status-file", type=Path, required=True)
    parser.add_argument("--log-file", type=Path, required=True)
    parser.add_argument("--fullscreen", action="store_true", help="unmanaged X11 window on primary monitor")
    args = parser.parse_args()
    ok, _ = Gtk.init_check([])
    if not ok:
        print("fng-splash: cannot open graphical display", file=sys.stderr)
        return 2
    try:
        splash = Splash(args)
    except (OSError, ValueError, KeyError, GLib.Error, configparser.Error) as exc:
        print(f"fng-splash: {exc}", file=sys.stderr)
        return 2
    Gtk.main()
    return splash.exit_code


if __name__ == "__main__":
    sys.exit(main())
