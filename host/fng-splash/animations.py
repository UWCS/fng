import math
import random

# logo morph + spinny dots go wheeee
class Spinner:
    def __init__(self, points, order, *, duration, radius, spacing, intro_hold, intro_morph,
                 speed_min, speed_max, speed_change_min_s, speed_change_max_s, dot_scale_wobble):
        n = len(points)
        if not n or sorted(order) != list(range(n)) or min(duration, radius, speed_min, speed_max) <= 0:
            raise ValueError("invalid spinner geometry or duration")
        self.points = [(x * radius, y * radius, colour) for x, y, colour in points]
        self.slots = [-math.pi + (order.index(i) + 0.5) * math.tau / n for i in range(n)]
        self.radius, self.spacing, self.duration = radius, spacing, duration
        self.hold, self.morph = intro_hold, intro_morph
        self.speed_range = speed_min, speed_max
        self.interval = speed_change_min_s, speed_change_max_s
        self.wobble = dot_scale_wobble
        self.angle = self.last = self.next_change = 0
        self.speed = self.target_speed = min(speed_max, max(speed_min, 1))
        self.scales = self.targets = [1] * n

    def positions(self, elapsed, rotation):
        t = min(1, max(0, (elapsed - self.hold) / self.morph)) if self.morph else float(elapsed >= self.hold)
        t = t * t * (3 - 2 * t)
        return [((1 - t) * x + t * self.spacing * math.cos(slot+rotation), (1 - t) * y + t * self.spacing * math.sin(slot + rotation), colour)
                for (x, y, colour), slot in zip(self.points, self.slots)]

    def advance(self, elapsed):
        dt = min(0.1, max(0, elapsed - self.last))
        self.last = elapsed
        if elapsed >= self.next_change:
            self.target_speed = random.uniform(*self.speed_range)
            self.targets = [random.uniform(1 - self.wobble, 1 + self.wobble) for _ in self.scales]
            self.next_change = elapsed + random.uniform(*self.interval)
        blend = 1 - math.exp(-1.5 * dt)
        self.speed += (self.target_speed - self.speed) * blend
        self.angle += math.tau * self.speed * dt / self.duration
        self.scales = [a + (b - a) * blend for a, b in zip(self.scales, self.targets)]

    def draw(self, cr, width, height, elapsed, animated=True):
        if animated:
            self.advance(max(0, elapsed-self.hold - self.morph))
        positions = self.positions(elapsed, self.angle) if animated else self.points
        cr.save()
        cr.translate(width / 2, height / 2)
        for (x,y,colour), scale in zip(positions, self.scales if animated else [1] * len(self.points)):
            cr.set_source_rgba(*colour)
            cr.arc(x, y, self.radius*scale, 0, math.tau)
            cr.fill()
        cr.restore()
