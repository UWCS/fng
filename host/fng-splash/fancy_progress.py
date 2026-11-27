import colorsys
import math


def fill_bounds(width, progress, elapsed, animated=True, segment=0.28, period=1.8):
    if progress >= 0:
        return 0, width * min(1, progress / 100)
    # continuous sweep w/ stationary part for reduced motion
    t = (0.5 - 0.5 * math.cos(math.tau * elapsed / period)) if animated else 0.5
    return width * (1 - segment) * t, width * segment


def rounded(cr, x, y, width, height, radius):
    r = min(radius, width/2, height/2)
    if r == 0:
        cr.rectangle(x, y, width, height)
        return
    cr.new_sub_path()
    cr.arc(x + width - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + width - r, y + height - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + height - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cr.close_path()


def paint(cairo, cr, width, height, progress, elapsed, *, animated=True, corner_radius, track, pulse, wave, gradient_speed, segment, period):
    if width <= 0 or height <= 0:
        return

    h, y = height, 0
    t = elapsed if animated else 0
    cr.save()
    rounded(cr, 0, y, width, h, corner_radius)
    cr.set_source_rgba(*track)
    cr.fill()
    x, length = fill_bounds(width, progress, t, animated, segment, period)
    if length > 0:
        rounded(cr, x, y, length, h, corner_radius)
        cr.clip()
        gradient = cairo.LinearGradient(0, 0, width, 0)
        brightness = 0.88 + 0.12 * math.sin(t * math.tau * 0.55) if pulse and animated else 1
        # sample hue
        for i in range(25):
            f = i / 24
            rgb = colorsys.hsv_to_rgb((f - t * gradient_speed)%1, 0.75, brightness)
            gradient.add_color_stop_rgb(f, *rgb)
        cr.set_source(gradient)
        cr.paint()
        if wave and animated:
            centre = ((t * 0.45) % 1.4 - 0.2) * width
            shimmer = cairo.LinearGradient(centre - 0.18 * width, 0, centre + 0.18 * width, 0)
            for stop, alpha in ((0, 0), (0.5, 0.28), (1, 0)):
                shimmer.add_color_stop_rgba(stop, 1, 1, 1, alpha)
            cr.set_source(shimmer)
            cr.paint()
    cr.restore()
