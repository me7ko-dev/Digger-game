"""Генерира текстурите на играта (почва, изкопана пръст, мръсотия по боята, грайфер на гуми).
Всичко е наша работа, без чужди файлове. Пуска се с: python3 tools/make_textures.py
Нужни: numpy, pillow.
"""
import os
import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(__file__), "..", "textures")
rng = np.random.default_rng(7)


def noise(n, beta, seed=None):
    """Периодичен шум (повтаря се без шев) с наклон на спектъра beta."""
    r = np.random.default_rng(seed) if seed is not None else rng
    f = np.fft.fftfreq(n)
    fx, fy = np.meshgrid(f, f)
    k = np.sqrt(fx ** 2 + fy ** 2)
    k[0, 0] = 1.0
    spec = (r.normal(size=(n, n)) + 1j * r.normal(size=(n, n))) / k ** beta
    spec[0, 0] = 0
    img = np.real(np.fft.ifft2(spec))
    img -= img.min()
    return img / img.max()


def band(n, lo, hi, seed=None):
    """Шум само в даден обхват от размери (в пиксели)."""
    r = np.random.default_rng(seed) if seed is not None else rng
    f = np.fft.fftfreq(n)
    fx, fy = np.meshgrid(f, f)
    k = np.sqrt(fx ** 2 + fy ** 2) * n
    mask = (k > n / hi) & (k < n / lo)
    spec = (r.normal(size=(n, n)) + 1j * r.normal(size=(n, n))) * mask
    img = np.real(np.fft.ifft2(spec))
    img -= img.min()
    return img / img.max()


def stones(n, count, rmin, rmax, seed):
    """Камъчета: височина (0..1) и оттенък за всяко, с увиване по краищата."""
    r = np.random.default_rng(seed)
    height = np.zeros((n, n))
    tint = np.zeros((n, n))
    for _ in range(count):
        cx, cy = r.uniform(0, n, 2)
        rad = r.uniform(rmin, rmax)
        ex = r.uniform(0.6, 1.0)        # сплеснатост
        ang = r.uniform(0, np.pi)
        t = r.uniform(-1, 1)
        R = int(rad + 2)
        xs = np.arange(int(cx) - R, int(cx) + R + 1)
        ys = np.arange(int(cy) - R, int(cy) + R + 1)
        X, Y = np.meshgrid(xs, ys)
        dx, dy = X - cx, Y - cy
        u = dx * np.cos(ang) + dy * np.sin(ang)
        v = (-dx * np.sin(ang) + dy * np.cos(ang)) / ex
        d = np.sqrt(u ** 2 + v ** 2) / rad
        h = np.clip(1 - d ** 2, 0, None) ** 0.5
        ix, iy = X % n, Y % n
        cur = height[iy, ix]
        upd = h > cur
        height[iy[upd], ix[upd]] = h[upd]
        tint[iy[upd], ix[upd]] = t
    return height, tint


def blur(img, sigma):
    """Периодично размазване (Гаус) през FFT."""
    n0, n1 = img.shape
    fy = np.fft.fftfreq(n0)[:, None]
    fx = np.fft.fftfreq(n1)[None, :]
    g = np.exp(-2 * (np.pi * sigma) ** 2 * (fx ** 2 + fy ** 2))
    return np.real(np.fft.ifft2(np.fft.fft2(img) * g))


def shade(h, strength):
    """Лека светлина отгоре-вляво и сенки в ниските места (запечени в цвета)."""
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * strength
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * strength
    light = np.clip(1 - 0.5 * (dx + dy), 0.5, 1.4)
    ao = np.clip(1 - (blur(h, 6) - h) * 1.5, 0.55, 1.0)
    return light * ao


def normal_map(h, strength):
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * strength
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * strength
    nz = np.ones_like(h)
    l = np.sqrt(dx ** 2 + dy ** 2 + nz ** 2)
    # OpenGL (Y+), както очаква Godot
    rgb = np.stack([(-dx / l + 1) / 2, (dy / l + 1) / 2, (nz / l + 1) / 2], -1)
    return rgb


def save(name, arr):
    arr = np.clip(arr, 0, 1)
    if arr.ndim == 2:
        img = Image.fromarray((arr * 255).astype(np.uint8), "L")
    else:
        img = Image.fromarray((arr * 255).astype(np.uint8), "RGB")
    path = os.path.join(OUT, name)
    img.save(path, quality=92) if name.endswith(".jpg") else img.save(path)
    print("saved", path)


def lerp_col(a, b, t):
    a, b = np.array(a), np.array(b)
    return a + (b - a) * t[..., None]


def soil(n=1024):
    """Суха пясъчна почва с камъчета (горният слой)."""
    big = noise(n, 1.5, 1)
    patches = band(n, 60, 400, 6)
    mid = band(n, 6, 60, 2)
    fine = band(n, 1, 4, 3)
    grains = band(n, 1, 2, 8)
    h1, t1 = stones(n, 1400, 2, 6, 4)
    h2, t2 = stones(n, 160, 6, 14, 5)
    bury = 0.25 + 0.5 * noise(n, 1.0, 9)          # частично заровени
    hs = np.clip(np.maximum(h1, h2) - bury * 0.6, 0, None)
    ts = np.where(h2 > h1, t2, t1)
    base = lerp_col((0.44, 0.35, 0.25), (0.64, 0.54, 0.40), big * 0.5 + mid * 0.5)
    damp = np.clip((patches - 0.55) * 3, 0, 1)
    base = base * (1 - 0.25 * damp)[..., None]
    base *= (0.82 + 0.3 * fine + 0.12 * (grains - 0.5))[..., None]
    stone_var = band(n, 1, 6, 10)
    stone_col = lerp_col((0.38, 0.36, 0.33), (0.70, 0.66, 0.58), np.clip((ts + 1) / 2 * 0.8 + stone_var * 0.3, 0, 1))
    m = np.clip(hs * 5, 0, 1)[..., None]
    col = base * (1 - m) + stone_col * m
    height = mid * 0.35 + fine * 0.2 + grains * 0.1 + hs * 1.6
    col *= shade(height, 2.5)[..., None]
    save("soil_diff.jpg", col)
    save("soil_nor.jpg", normal_map(height, 3.0))
    save("soil_rough.jpg", 0.95 - 0.25 * m[..., 0])


def dirt(n=1024):
    """Прясно изкопана, по-влажна и по-тъмна пръст на буци."""
    big = noise(n, 1.3, 11)
    clods = band(n, 10, 50, 12)
    small = band(n, 3, 10, 15)
    fine = band(n, 1, 3, 13)
    h1, t1 = stones(n, 700, 1.5, 5, 14)
    lumps = np.clip(clods * 1.3 - 0.35, 0, 1) ** 1.5
    height = lumps * 1.6 + small * 0.4 + fine * 0.2 + h1 * 0.8
    base = lerp_col((0.20, 0.15, 0.10), (0.38, 0.29, 0.20), big * 0.5 + lumps * 0.5)
    base *= (0.8 + 0.4 * fine)[..., None]
    m = np.clip(h1 * 3, 0, 1)[..., None]
    stone_col = lerp_col((0.33, 0.30, 0.27), (0.52, 0.47, 0.41), (t1 + 1) / 2)
    col = base * (1 - m) + stone_col * m
    col *= shade(height, 3.0)[..., None]
    save("dirt_diff.jpg", col)
    save("dirt_nor.jpg", normal_map(height, 4.0))


def grime(n=512):
    """Сива маска за прах и мръсотия по боята и метала."""
    g = noise(n, 1.2, 21) * 0.6 + band(n, 2, 12, 22) * 0.4
    g = (g - g.min()) / (g.max() - g.min())
    save("grime.png", g)


def tread(w=512, h=128):
    """Нормали за грайфера на гумите: шеврони по обиколката (u) и ширината (v)."""
    y, x = np.mgrid[0:h, 0:w].astype(float)
    period = w / 32.0                 # 32 блока по обиколката
    v = (y / h - 0.5) * 2             # -1..1 по ширината
    phase = (x + np.abs(v) * period * 0.9) / period
    groove = np.abs((phase % 1.0) - 0.5) * 2    # 0 в канала
    height = np.clip(groove * 3 - 0.9, 0, 1)
    height *= np.clip((1 - np.abs(v)) * 6, 0, 1) * 0.3 + 0.7
    height[np.abs(v) < 0.08] = 1.0    # среден ръб
    save("tread_nor.png", normal_map(height, 2.5))


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    soil()
    dirt()
    grime()
    tread()
