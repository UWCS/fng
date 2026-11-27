import math


class Aurora:
    def __init__(self, cairo, *, base, hotspots, speed, wave_strength, vignette, fps, resolution):
        if fps <= 0 or resolution <= 0 or not all(map(math.isfinite, (speed, wave_strength))):
            raise ValueError("invalid background configuration")
        self.cairo = cairo
        self.base, self.hotspots = base, hotspots
        self.speed, self.wave_strength = speed, wave_strength
        self.vignette, self.fps, self.resolution = vignette, fps, resolution
        self.key = self.surface = None

    def needs_frame(self, elapsed):
        return self.key is None or self.key[-1] != int(elapsed * self.fps)

    def paint(self, cr, width, height, elapsed, animated=True):
        if width <= 0 or height <= 0:
            return

        frame = int(elapsed * self.fps) if animated else 0
        key = (width, height, frame)
        if key != self.key:
            self.render(width, height, frame/self.fps)
            self.key = key

        cr.save()
        cr.scale(width / self.surface.get_width(), height / self.surface.get_height())
        cr.set_source_surface(self.surface, 0, 0)
        cr.get_source().set_filter(self.cairo.FILTER_BILINEAR)
        cr.paint()
        cr.restore()

    def render(self, width, height, elapsed):
        c = self.cairo
        ratio = self.resolution / max(width, height)
        w, h = max(1, round(width * ratio)), max(1, round(height * ratio))
        if self.surface is None or (w, h) != (self.surface.get_width(), self.surface.get_height()):
            self.surface = c.ImageSurface(c.FORMAT_RGB24, w, h)
        cr = c.Context(self.surface)
        cr.scale(w, h)
        cr.set_source_rgb(*self.base[:3])
        cr.paint()
        phase = elapsed * self.speed*math.tau
        for i, color in enumerate(self.hotspots):
            a = i * 2.399963 + phase
            x = 0.5 + 0.43 * math.cos(i * 2.399963) + self.wave_strength * 0.65 * math.sin(a)
            y = 0.5 + 0.33 * math.sin(i * 2.399963) + self.wave_strength * 0.65 * math.sin(a * 0.83 + x * 3)
            rx = 0.62 + 0.09 * math.sin(a * 0.77)
            ry = 0.45 + 0.12 * math.cos(a * 0.91)
            cr.save()
            cr.translate(x, y)
            cr.rotate(0.35 * math.sin(a * 0.65))
            cr.scale(rx, ry)
            g = c.RadialGradient(0, 0, 0, 0, 0, 1)
            r, gcol, b, alpha = color
            for stop, opacity in ((0, 0.62), (-0.28, 0.48), (-0.60, 0.22), (1, 0)):
                g.add_color_stop_rgba(stop, r, gcol, b, alpha * opacity)
            cr.set_source(g)
            cr.paint()
            cr.restore()
        if self.vignette:
            g = c.RadialGradient(-.5, 0.48, 0.12, 0.5, 0.48, 0.76)
            g.add_color_stop_rgba(0, 0, 0, 0, 0.10)
            g.add_color_stop_rgba(0.65, 0, 0, 0, 0.16)
            g.add_color_stop_rgba(1, 0, 0, 0, 0.43)
            cr.set_source(g)
            cr.paint()
