#!/usr/bin/env python3
"""Renders the pixel-art grids from Tools/icon/art.js into macOS icon images (pure Python, no deps):
rounded-square mask with the standard 10 % margin, nearest-neighbour scaling when enlarging and
3x3 supersampling when shrinking."""
import json, zlib, struct, base64, sys

def hexrgb(h): h = h.lstrip('#'); return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))

def png(w, h, rgba):
    raw = b''.join(b'\x00' + bytes(rgba[y*w*4:(y+1)*w*4]) for y in range(h))
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')

def coverage(x, y, x0, size, r, n=4):
    cov = 0
    for sy in range(n):
        for sx in range(n):
            px, py = x + (sx + .5) / n, y + (sy + .5) / n
            cx = min(max(px, x0 + r), x0 + size - r); cy = min(max(py, x0 + r), x0 + size - r)
            if (px - cx) ** 2 + (py - cy) ** 2 <= r * r: cov += 1
    return cov / (n * n)

def icon(opt, S):
    inset = S * 0.1; box = S - 2 * inset; r = box * 0.225
    aw, ah = opt['w'], opt['h']
    px = [hexrgb(p) if p else None for p in opt['px']]
    fallback = hexrgb(opt['bg'][1])
    k = box / aw                      # output pixels per art pixel
    n = 1 if k >= 2 else 3            # supersample when shrinking or scaling unevenly
    out = bytearray(S * S * 4)
    for y in range(S):
        for x in range(S):
            if x < inset - 1 or y < inset - 1 or x > S - inset or y > S - inset: continue
            a = coverage(x, y, inset, box, r)
            if a == 0: continue
            acc = [0, 0, 0]
            for sy in range(n):
                for sx in range(n):
                    ax = int((x + (sx + .5) / n - inset) / k); ay = int((y + (sy + .5) / n - inset) / k)
                    c = px[min(ah - 1, max(0, ay)) * aw + min(aw - 1, max(0, ax))] or fallback
                    acc[0] += c[0]; acc[1] += c[1]; acc[2] += c[2]
            i = (y * S + x) * 4
            out[i:i+4] = bytes([round(acc[0] / n / n), round(acc[1] / n / n), round(acc[2] / n / n), round(255 * a)])
    return png(S, S, out)

# Usage: render.py icon-art.json Resources/
# Writes <name>.iconset/ (+ <name>.icns via iconutil) for AppIcon and a 1024 px PNG for each icon.
import os, subprocess
art_path, out_dir = sys.argv[1], sys.argv[2]
for o in json.load(open(art_path)):
    name = o['key']
    with open(os.path.join(out_dir, f'{name}.png'), 'wb') as f: f.write(icon(o, 1024))
    if name == 'AppIcon':
        iconset = os.path.join(out_dir, 'AppIcon.iconset'); os.makedirs(iconset, exist_ok=True)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = '' if scale == 1 else '@2x'
                with open(os.path.join(iconset, f'icon_{size}x{size}{suffix}.png'), 'wb') as f: f.write(icon(o, size * scale))
        subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', os.path.join(out_dir, 'AppIcon.icns')], check=True)
        subprocess.run(['rm', '-rf', iconset], check=True)
    print(name, 'ok', file=sys.stderr)
