"""Turn gray PGM frames into an animated GIF with 16 gray levels (what an
e-ink screen shows). Standard library only.

    python3 make_gif.py out.gif delay_ms [crop_height] frame1.pgm frame2.pgm ...

crop_height (optional) keeps only the top rows of each frame.
"""
import struct
import sys


def read_pgm(path):
    with open(path, "rb") as f:
        data = f.read()
    parts = data.split(maxsplit=4)
    assert parts[0] == b"P5", "not a binary PGM"
    w, h, maxval = int(parts[1]), int(parts[2]), int(parts[3])
    pixels = parts[4][: w * h]
    return w, h, bytes(p * 255 // maxval for p in pixels)


def lzw(indices, min_code_size):
    """GIF LZW: returns the packed sub-blocks."""
    clear = 1 << min_code_size
    end = clear + 1
    out_bits, n_bits, codes = 0, 0, bytearray()
    size = min_code_size + 1

    def emit(code):
        nonlocal out_bits, n_bits
        out_bits |= code << n_bits
        n_bits += size
        while n_bits >= 8:
            codes.append(out_bits & 0xFF)
            out_bits >>= 8
            n_bits -= 8

    table = {bytes([i]): i for i in range(clear)}
    next_code = end + 1
    emit(clear)
    w = b""
    for b in indices:
        wc = w + bytes([b])
        if wc in table:
            w = wc
            continue
        emit(table[w])
        if next_code < 4096:
            table[wc] = next_code
            next_code += 1
            if next_code > (1 << size) and size < 12:
                size += 1
        else:
            emit(clear)
            table = {bytes([i]): i for i in range(clear)}
            next_code = end + 1
            size = min_code_size + 1
        w = bytes([b])
    if w:
        emit(table[w])
    emit(end)
    if n_bits:
        codes.append(out_bits & 0xFF)
    blocks = bytearray()
    for i in range(0, len(codes), 255):
        chunk = codes[i : i + 255]
        blocks.append(len(chunk))
        blocks += chunk
    blocks.append(0)
    return bytes(blocks)


def main():
    out, delay_ms, paths = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
    crop = None
    if paths and paths[0].isdigit():
        crop, paths = int(paths[0]), paths[1:]
    frames = [read_pgm(p) for p in paths]
    if crop:
        frames = [(w, min(h, crop), px[: w * min(h, crop)]) for w, h, px in frames]
    w, h = frames[0][0], frames[0][1]
    gif = bytearray(b"GIF89a")
    gif += struct.pack("<HHBBB", w, h, 0xF3, 0, 0)  # global table of 16 colours
    for i in range(16):
        gif += bytes([i * 17] * 3)
    gif += b"\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00"  # loop forever
    for _w, _h, pixels in frames:
        gif += b"\x21\xF9\x04\x00" + struct.pack("<H", delay_ms // 10) + b"\x00\x00"
        gif += b"\x2C" + struct.pack("<HHHHB", 0, 0, w, h, 0)
        gif.append(4)  # LZW minimum code size for 16 colours
        gif += lzw(bytes(p >> 4 for p in pixels), 4)
    gif.append(0x3B)
    with open(out, "wb") as f:
        f.write(gif)
    print("wrote", out, len(gif), "bytes")


if __name__ == "__main__":
    main()
