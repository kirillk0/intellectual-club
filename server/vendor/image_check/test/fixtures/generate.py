#!/usr/bin/env python3
"""Regenerates the ImageCheck test fixtures with independent encoders.

Requires Pillow (with WebP and AVIF support) and pypng:

    pip3 install pillow pypng
    python3 test/fixtures/generate.py
"""

import io
import os

import png
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))


def gradient(mode, width, height):
    image = Image.new("RGB", (width, height))
    image.putdata(
        [((x * 37) % 256, (y * 53) % 256, ((x + y) * 29) % 256) for y in range(height) for x in range(width)]
    )
    return image.convert(mode)


def save(name, image, **options):
    image.save(os.path.join(HERE, name), **options)


def write(name, payload):
    with open(os.path.join(HERE, name), "wb") as handle:
        handle.write(payload)


def pypng(name, width, height, **options):
    options.setdefault("greyscale", False)
    rows = []
    planes = 3 if not options.get("greyscale") else 1
    planes += 1 if options.get("alpha") else 0
    if options.get("palette"):
        planes = 1
    maximum = 2 ** options.get("bitdepth", 8) - 1
    for y in range(height):
        row = []
        for x in range(width):
            for plane in range(planes):
                row.append(((x * 7 + y * 13 + plane * 3) % (maximum + 1)))
        rows.append(row)
    buffer = io.BytesIO()
    png.Writer(width, height, **options).write(buffer, rows)
    write(name, buffer.getvalue())


def noise(width, height):
    image = Image.new("RGB", (width, height))
    image.putdata(
        [((x * x * 31 + y * 17) % 256, (x * y * 7 + y * y) % 256, (x * 13 + y * y * 5) % 256) for y in range(height) for x in range(width)]
    )
    return image


# JPEG
save("photo.jpg", noise(96, 64), quality=90)
save("photo_progressive.jpg", noise(96, 64), quality=90, progressive=True)
save("baseline.jpg", gradient("RGB", 17, 9), quality=80, subsampling=2)
save("baseline_444.jpg", gradient("RGB", 8, 8), quality=90, subsampling=0, exif=b"Exif\x00\x00MM\x00*\x00\x00\x00\x08\x00\x00")
save("progressive.jpg", gradient("RGB", 32, 24), quality=75, progressive=True)
save("cmyk.jpg", gradient("CMYK", 16, 16), quality=80)
save("grayscale.jpg", gradient("L", 12, 10), quality=80)
save("restart.jpg", gradient("RGB", 40, 24), quality=80, restart_marker_blocks=1)

# PNG
save("rgb.png", gradient("RGB", 7, 5))
save("gray16.png", gradient("RGB", 5, 4).convert("I;16"))
save("palette.png", gradient("P", 9, 3), transparency=0)
save("gray1.png", gradient("1", 13, 5))
pypng("rgba16_pypng.png", 6, 5, alpha=True, bitdepth=16)
pypng("adam7_rgb.png", 11, 9, interlace=True)
pypng("adam7_gray2.png", 5, 3, greyscale=True, bitdepth=2, interlace=True)
pypng("adam7_1x1.png", 1, 1, greyscale=True, alpha=True, interlace=True)
pypng("adam7_rgba16.png", 3, 17, alpha=True, bitdepth=16, interlace=True)
frames = [gradient("RGBA", 6, 4), gradient("RGBA", 6, 4).rotate(180)]
save("animated.png", frames[0], save_all=True, append_images=frames[1:], duration=100, loop=0)

# GIF
save("static.gif", gradient("P", 9, 7))
frames = [gradient("P", 8, 6), gradient("RGB", 8, 6).rotate(180).convert("P"), gradient("P", 8, 6)]
save("animated.gif", frames[0], save_all=True, append_images=frames[1:], duration=[50, 60, 70], loop=0, transparency=0)

# WebP
save("lossy.webp", gradient("RGB", 10, 6), quality=80)
save("lossless.webp", gradient("RGB", 10, 6), lossless=True)
save("alpha.webp", gradient("RGBA", 10, 6).rotate(30), quality=80)
frames = [gradient("RGB", 12, 8), gradient("RGB", 12, 8).rotate(180)]
save("animated.webp", frames[0], save_all=True, append_images=frames[1:], duration=80, loop=0, quality=70)

save("icc.webp", gradient("RGB", 6, 4), quality=80, icc_profile=b"\x00" * 128, exif=b"Exif\x00\x00")

# Formats rejected by providers
save("image.bmp", gradient("RGB", 4, 4))
save("image.tiff", gradient("RGB", 4, 4))
save("image.avif", gradient("RGB", 8, 8))
