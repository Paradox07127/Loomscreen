"""Minimal WPE .tex (TEXV0005 / TEXB v4) decoder -> RGBA, for atlas part identification."""
import struct, sys

def read_cstr(d, o):
    e = d.index(b'\x00', o)
    return d[o:e].decode('latin1'), e + 1

def parse_tex(data):
    o = 0
    def magic():
        nonlocal o
        m = data[o:o+8].decode('latin1'); o += 8
        if data[o:o+1] == b'\x00': o += 1  # some magics null-padded to 9
        return m
    cont = data[o:o+8]; o += 8  # TEXV0005
    if data[o:o+1] == b'\x00': o += 1
    # TEXI block
    timag = data[o:o+8]; o += 8
    if data[o:o+1] == b'\x00': o += 1
    fmt, flags, tw, th, iw, ih, unk0 = struct.unpack_from('<iIiiiii', data, o); o += 28
    # next: TEXB
    tb = data[o:o+8]; o += 8
    if data[o:o+1] == b'\x00': o += 1
    bitmapVersion = int(tb[4:].decode('latin1'))  # TEXB0004 -> 4
    imageCount, = struct.unpack_from('<i', data, o); o += 4
    # imageFormat (v>=...), isVideo
    # Based on decoder: for v>=? imageFormat then isVideo. Probe heuristically.
    imageFormat, = struct.unpack_from('<i', data, o); o += 4
    isVideo, = struct.unpack_from('<i', data, o); o += 4
    mips = []
    mipCount, = struct.unpack_from('<i', data, o); o += 4
    for mi in range(mipCount):
        mw, mh = struct.unpack_from('<ii', data, o); o += 8
        comp, decomp = struct.unpack_from('<II', data, o); o += 8
        stored, = struct.unpack_from('<I', data, o); o += 4
        payload = data[o:o+stored]; o += stored
        mips.append(dict(index=mi, w=mw, h=mh, compressed=comp, decompressed=decomp, stored=stored, payload=payload))
    return dict(format=fmt, width=tw, height=th, imageW=iw, imageH=ih, mips=mips)

def lz4_raw_decompress(payload, out_size):
    try:
        import lz4.block
        return lz4.block.decompress(payload, uncompressed_size=out_size)
    except Exception:
        return None

def bc3_decode(block_bytes, w, h):
    # BC3 = 8 bytes BC4 alpha + 8 bytes BC1 color per 4x4 block
    out = bytearray(w*h*4)
    bw, bh = (w+3)//4, (h+3)//4
    p = 0
    for by in range(bh):
        for bx in range(bw):
            a0, a1 = block_bytes[p], block_bytes[p+1]
            abits = int.from_bytes(block_bytes[p+2:p+8], 'little')
            alphas = [a0, a1]
            if a0 > a1:
                for i in range(1,7): alphas.append(((7-i)*a0 + i*a1)//7)
            else:
                for i in range(1,5): alphas.append(((5-i)*a0 + i*a1)//5)
                alphas += [0,255]
            c0, c1 = struct.unpack_from('<HH', block_bytes, p+8)
            cbits, = struct.unpack_from('<I', block_bytes, p+12)
            def rgb(c):
                r=(c>>11)&31; g=(c>>5)&63; b=c&31
                return [r*255//31, g*255//63, b*255//31]
            cols=[rgb(c0), rgb(c1)]
            if c0>c1:
                cols.append([(2*cols[0][i]+cols[1][i])//3 for i in range(3)])
                cols.append([(cols[0][i]+2*cols[1][i])//3 for i in range(3)])
            else:
                cols.append([(cols[0][i]+cols[1][i])//2 for i in range(3)])
                cols.append([0,0,0])
            for py in range(4):
                for px in range(4):
                    x, y = bx*4+px, by*4+py
                    if x>=w or y>=h: continue
                    ci = (cbits >> (2*(py*4+px))) & 3
                    ai = (abits >> (3*(py*4+px))) & 7
                    r,g,b = cols[ci]; a = alphas[ai]
                    idx=(y*w+x)*4
                    out[idx:idx+4]=bytes([r,g,b,a])
            p += 16
    return bytes(out)

def write_ppm(rgba, w, h, path):
    # write RGB PPM (drop alpha) for easy viewing
    with open(path,'wb') as f:
        f.write(b'P6\n%d %d\n255\n'%(w,h))
        for i in range(w*h):
            f.write(rgba[i*4:i*4+3])

if __name__ == '__main__':
    data = open(sys.argv[1],'rb').read()
    tex = parse_tex(data)
    print(f"format={tex['format']} {tex['width']}x{tex['height']} mips={[(m['w'],m['h'],m['compressed'],m['stored'],m['decompressed']) for m in tex['mips']]}")
    # pick mip0 (LZ4) if decompressable, else largest uncompressed
    target = None
    for m in tex['mips']:
        if m['compressed']:
            raw = lz4_raw_decompress(m['payload'], m['decompressed'])
            if raw: m2=dict(m); m2['payload']=raw; target=m2; break
        else:
            target=m; break
    if target is None:
        # fall back to first uncompressed mip
        for m in tex['mips']:
            if not m['compressed']: target=m; break
    print(f"decoding mip {target['index']} {target['w']}x{target['h']} (payload {len(target['payload'])})")
    rgba = bc3_decode(target['payload'], target['w'], target['h'])
    write_ppm(rgba, target['w'], target['h'], sys.argv[2])
    print(f"wrote {sys.argv[2]}")
