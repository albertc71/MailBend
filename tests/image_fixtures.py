"""Image files for the tests, built with the standard library alone: a valid
PNG of any size (black, or noise from a seed, which does not compress), a
valid flat grey baseline JPEG, and a PNG whose header MailBend reads but
which no decoder can open."""

import random
import struct
import zlib

PNG_SIGNATURE = bytes([137, 80, 78, 71, 13, 10, 26, 10])


def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def png(width, height, seed=None):
    """An 8-bit RGB PNG: black, or random pixels from `seed`, stored with
    no compression so its size is about width * height * 3 bytes."""
    if seed is None:
        rows = b"".join(b"\0" + bytes(width * 3) for _ in range(height))
        data = zlib.compress(rows)
    else:
        noise = random.Random(seed)
        rows = b"".join(b"\0" + noise.randbytes(width * 3) for _ in range(height))
        data = zlib.compress(rows, 0)
    return (PNG_SIGNATURE + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + png_chunk(b"IDAT", data) + png_chunk(b"IEND", b""))


def damaged_png():
    """A 280 by 280 PNG whose IHDR MailBend reads, but whose IHDR CRC is zero
    and whose image data is not deflated."""
    return bytes([
        137, 80, 78, 71, 13, 10, 26, 10,
        0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 1, 24, 0, 0, 1, 24, 8, 2, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 73, 68, 65, 84, 0, 0, 0, 0,
    ])


def jpeg(width, height):
    """A flat grey baseline JPEG with one component. Its two Huffman tables
    hold two codes each, so every 8 by 8 block is DC difference 0 ("0") and
    end of block ("0"): two bits."""
    blocks = ((width + 7) // 8) * ((height + 7) // 8)
    bits = 2 * blocks
    scan = bytes(bits // 8) + (bytes([0xFF >> (bits % 8)]) if bits % 8 else b"")

    def segment(marker, body):
        return bytes([0xFF, marker]) + struct.pack(">H", len(body) + 2) + body

    table = bytes([0, 1, 1] + [0] * 13)
    return (b"\xff\xd8"
            + segment(0xDB, bytes([0]) + bytes([1] * 64))
            + segment(0xC0, bytes([8]) + struct.pack(">HH", height, width) + bytes([1, 1, 0x11, 0]))
            + segment(0xC4, bytes([0x00]) + table + bytes([0, 1]))
            + segment(0xC4, bytes([0x10]) + table + bytes([0x00, 0xF0]))
            + segment(0xDA, bytes([1, 1, 0x00, 0, 63, 0]))
            + scan + b"\xff\xd9")
