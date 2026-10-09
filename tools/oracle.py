"""Independent test-input generator and oracle, never imported by the Bend library.

Python's zlib encodes the fixtures; ImageMagick independently decodes real PNGs.
All decoding under test is performed by the explicitly supplied Bend binary
(examples/decode.bend), one process at a time.

    python3 tools/oracle.py --prepare-only
        Regenerate fixtures/ and the Bend tables fixtures/cases.bend and
        fixtures/reads.bend. Generation is seeded; the expected pixels are
        fixed, while the compressed bytes depend on the local zlib.
    python3 tools/oracle.py --verify build/decode [--real]
        Decode every fixture with the binary and compare its RGBA output byte
        for byte; invalid fixtures must exit 1 with the expected message.
        --real also decodes four PNGs from /usr/share/pixmaps and compares
        them with ImageMagick (`magick` must be installed).
"""
from pathlib import Path
import binascii
import argparse
import hashlib
import json
import random
import struct
import subprocess
import time
import zlib

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / 'fixtures'
REAL_PNGS = ('filezilla', 'kitty', 'nvim', 'helium-browser')
SIGNATURE = b'\x89PNG\r\n\x1a\n'


def chunk(kind, body):
    return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', binascii.crc32(kind + body))


def png(w, h, color, stream, depth=8, interlace=0, before=b'', split=False):
    header = chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, depth, color, 0, 0, interlace))
    idat = chunk(b'IDAT', stream)
    if split:
        idat = chunk(b'IDAT', b'') + b''.join(chunk(b'IDAT', stream[i:i+7]) for i in range(0, len(stream), 7))
    return SIGNATURE + header + before + idat + chunk(b'IEND', b'')


def filtered(rows, bpp, filters):
    """Independent PNG *encoder* for controlled filter coverage."""
    result = bytearray()
    previous = bytes(len(rows[0]))
    for row, f in zip(rows, filters):
        result.append(f)
        for x, value in enumerate(row):
            a, b, c = row[x-bpp] if x >= bpp else 0, previous[x], previous[x-bpp] if x >= bpp else 0
            p = a+b-c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            paeth = a if pa <= pb and pa <= pc else b if pb <= pc else c
            predictor = (0, a, b, (a+b)//2, paeth)[f]
            result.append((value-predictor) & 255)
        previous = row
    return bytes(result)


def encoded(raw, mode):
    c = zlib.compressobj(0 if mode == 'stored' else 6, zlib.DEFLATED, 15, 8,
                         zlib.Z_FIXED if mode == 'fixed' else zlib.Z_DEFAULT_STRATEGY)
    return c.compress(raw) + c.flush()


def fixtures():
    FIX.mkdir(exist_ok=True)
    ok, bad = [], []
    def good(name, data, expected):
        (FIX / (name + '.png')).write_bytes(data)
        (FIX / (name + '.rgba')).write_bytes(expected)
        ok.append((name, binascii.crc32(expected)))
    def invalid(name, data, message):
        (FIX / (name + '.png')).write_bytes(data)
        bad.append((name, message))
    for bpp in (3, 4):
        w, h = 19, 10
        rows = [bytes((x*17+y*41+(x//bpp)*y*3) % 256 for x in range(w*bpp)) for y in range(h)]
        expected = b''.join(row if bpp == 4 else b''.join(row[x:x+3]+b'\xff' for x in range(0,len(row),3)) for row in rows)
        for mode in ('stored', 'fixed', 'dynamic'):
            stream = encoded(filtered(rows,bpp,[i%5 for i in range(h)]),mode)
            good(f'rgb{bpp*8}-{mode}-filters',png(w,h,6 if bpp==4 else 2,stream,split=True),expected)
    for f in range(5):
        rows = [bytes([255,0,128,0]), bytes([0,255,127,255])]
        good(f'one-pixel-filter-{f}',png(1,2,6,encoded(filtered(rows,4,[f,f]),'fixed')),b''.join(rows))
    rows = [bytes([0,0,0,255])*64 for _ in range(64)]
    stream = encoded(filtered(rows,4,[0]*64),'dynamic')
    assert (stream[2] >> 1) & 3 == 2, 'fixture must exercise a dynamic Huffman block'
    good('dynamic-huffman-overlap',png(64,64,6,stream),b''.join(rows))
    rng = random.Random(20261006)
    for i in range(20):
        w,h,bpp = rng.randrange(1,80),rng.randrange(1,30),rng.choice([3,4])
        rows = [rng.randbytes(w*bpp) for _ in range(h)]
        expected = b''.join(row if bpp==4 else b''.join(row[x:x+3]+b'\xff' for x in range(0,len(row),3)) for row in rows)
        good(f'random-{i:02}',png(w,h,6 if bpp==4 else 2,encoded(filtered(rows,bpp,[rng.randrange(5) for _ in rows]),rng.choice(['stored','fixed','dynamic']))),expected)
    raw = b'\x00\xff\x00\x80\x7f'
    stream = encoded(raw,'fixed')
    base = png(1,1,6,stream)
    good('metadata',png(1,1,6,stream,before=chunk(b'sRGB',b'\x00')+chunk(b'gAMA',struct.pack('>I',45455))+chunk(b'pHYs',struct.pack('>IIB',3780,3780,1))+chunk(b'PLTE',bytes([1,2,3]))),raw[1:])
    good('metadata-gamma-before-srgb',png(1,1,6,stream,before=chunk(b'gAMA',struct.pack('>I',45455))+chunk(b'sRGB',b'\x00')),raw[1:])
    for cut in (0,1,7,8,12,16,28,32,33,len(base)-1,len(base)-12):
        invalid(f'truncated-{cut}',base[:cut],'')
    invalid('bad-signature',b'BAD'+base[3:],'signature')
    corrupt=bytearray(base);corrupt[29]^=1
    invalid('bad-crc',bytes(corrupt),'CRC-32')
    invalid('bad-adler',png(1,1,6,stream[:-1]+bytes([stream[-1]^1])),'Adler-32')
    invalid('trailing-png',base+b'x','trailing')
    invalid('trailing-zlib',png(1,1,6,stream+b'x'),'trailing')
    invalid('bad-fcheck',png(1,1,6,bytes([120,0])+stream[2:]),'FCHECK')
    invalid('dictionary',png(1,1,6,bytes([120,32])+stream[2:]),'dictionary')
    invalid('small-window',png(1,1,6,bytes([8,29])+stream[2:]),'zlib header')
    invalid('bad-filter',png(1,1,6,encoded(b'\x05'+raw[1:],'fixed')),'scanline filter')
    invalid('short-output',png(1,1,6,encoded(raw[:-1],'fixed')),'shorter')
    invalid('long-output',png(1,1,6,encoded(raw+b'x','fixed')),'exceeds')
    invalid('zero-width',png(0,1,6,stream),'dimensions')
    invalid('large-dimensions',png(4294967295,4294967295,6,stream),'dimensions')
    invalid('pixel-limit',png(4096,4096,6,stream),'allocation')
    invalid('grayscale',png(1,1,0,stream),'color type')
    invalid('indexed',png(1,1,3,stream),'color type')
    invalid('depth-16',png(1,1,6,stream,depth=16),'bit depth')
    invalid('adam7',png(1,1,6,stream,interlace=1),'interlace')
    invalid('trns',png(1,1,6,stream,before=chunk(b'tRNS',b'\0'*6)),'unsupported PNG chunk')
    invalid('icc',png(1,1,6,stream,before=chunk(b'iCCP',b'x\0\0')),'unsupported PNG chunk')
    invalid('non-srgb-gamma',png(1,1,6,stream,before=chunk(b'gAMA',struct.pack('>I',100000))),'gAMA')
    invalid('gamma-without-srgb',png(1,1,6,stream,before=chunk(b'gAMA',struct.pack('>I',45455))),'color conversion')
    invalid('duplicate-ihdr',base[:33]+base[8:33]+base[33:],'unsupported PNG chunk')
    invalid('empty-plte',png(1,1,6,stream,before=chunk(b'PLTE',b'')),'PLTE')
    invalid('invalid-reserved-bit',png(1,1,6,stream,before=chunk(b'abcd',b'')),'chunk type')
    invalid('huge-chunk',SIGNATURE+struct.pack('>I',0xffffffff)+b'IHDR','chunk length')
    invalid('reserved-block',png(1,1,6,bytes([120,156,7,0,0,0,1])),'reserved DEFLATE block')
    invalid('stored-complement',png(1,1,6,bytes([120,1,1,5,0,0,0])+raw+struct.pack('>I',zlib.adler32(raw))),'complement')
    invalid('no-idat',base[:33]+chunk(b'IEND',b''),'IEND')
    invalid('oversize-input',base+bytes(2097153-len(base)),'2 MiB')
    # Decoder-path coverage, added with the table-driven inflate. A separate
    # generator keeps every earlier fixture byte for byte.
    more = random.Random(20261009)
    rows = [bytes(skewed(more) for _ in range(64*4)) for _ in range(64)]
    stream = encoded_with(filtered(rows,4,[0]*64),9,zlib.Z_HUFFMAN_ONLY)
    assert max_literal_code_length(stream) > 9, 'fixture must exercise literal codes longer than 9 bits'
    good('long-huffman-codes',png(64,64,6,stream),b''.join(rows))
    rows = [bytes((x*7+y*13+more.randrange(4)) % 256 for x in range(40*3)) for y in range(24)]
    raw = filtered(rows,3,[y%5 for y in range(24)])
    good('mixed-blocks',png(40,24,2,mixed_blocks(raw)),b''.join(b''.join(r[x:x+3]+b'\xff' for x in range(0,len(r),3)) for r in rows))
    invalid('truncated-deflate',png(64,64,6,stream[:len(stream)//2]),'truncated DEFLATE')
    return ok,bad


def skewed(rng):
    """A byte with a geometric distribution, so rare values get long codes."""
    v = 0
    while v < 255 and rng.random() < 0.55:
        v += 1
    return v


def encoded_with(raw, level, strategy):
    c = zlib.compressobj(level, zlib.DEFLATED, 15, 8, strategy)
    return c.compress(raw) + c.flush()


def mixed_blocks(raw):
    """A zlib stream of stored, fixed and dynamic blocks, plus the empty stored
    blocks of full flushes. Raw DEFLATE segments that end on a full flush are
    byte aligned, so they concatenate into one valid stream."""
    third = len(raw) // 3
    parts = [(raw[:third], 0, zlib.Z_DEFAULT_STRATEGY), (raw[third:2*third], 6, zlib.Z_FIXED), (raw[2*third:], 9, zlib.Z_DEFAULT_STRATEGY)]
    body = b''
    for i, (part, level, strategy) in enumerate(parts):
        c = zlib.compressobj(level, zlib.DEFLATED, -15, 8, strategy)
        body += c.compress(part) + c.flush(zlib.Z_FINISH if i == len(parts) - 1 else zlib.Z_FULL_FLUSH)
    return bytes([120, 156]) + body + struct.pack('>I', zlib.adler32(raw))


def max_literal_code_length(stream):
    """Longest literal/length code of the first block, which must be dynamic."""
    bits, pos = int.from_bytes(stream[2:], 'little'), 0
    def take(n):
        nonlocal pos
        value = (bits >> pos) & ((1 << n) - 1)
        pos += n
        return value
    take(1)
    assert take(2) == 2, 'first block must be dynamic'
    hlit, hdist, hclen = take(5) + 257, take(5) + 1, take(4) + 4
    lengths19 = [0] * 19
    for i in range(hclen):
        lengths19[[16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15][i]] = take(3)
    codes, code = {}, 0
    for length in range(1, 8):
        for sym in range(19):
            if lengths19[sym] == length:
                codes[(length, code)] = sym
                code += 1
        code <<= 1
    lengths = []
    while len(lengths) < hlit + hdist:
        code = 0
        for length in range(1, 8):
            code = (code << 1) | take(1)
            if (length, code) in codes:
                sym = codes[(length, code)]
                break
        if sym < 16:
            lengths.append(sym)
        elif sym == 16:
            lengths += [lengths[-1]] * (3 + take(2))
        else:
            lengths += [0] * ((3 + take(3)) if sym == 17 else (11 + take(7)))
    return max(lengths[:hlit])


def prepare():
    ok,bad=fixtures()
    cases='import Base\n\ndef valid() -> List<(String & U32)>:\n  ['+',\n   '.join('("'+n+'", '+str(crc)+')' for n,crc in ok)+']\n\ndef invalid() -> +List<String>:\n  ['+',\n   '.join('"'+n+'"' for n,_ in bad)+']\n'
    (FIX/'cases.bend').write_text(cases)
    reads=[]
    for name,size in [('io-empty',0),('io-small',100),('io-chunk-minus-one',65535),
                      ('io-chunk',65536),('io-chunk-plus-one',65537),
                      ('io-limit',2097152),('io-overlimit',2097409)]:
        data=(bytes(range(256))*((size+255)//256))[:size]
        (FIX/(name+'.bin')).write_bytes(data)
        expected=data[:2097153]
        reads.append((name,len(expected),binascii.crc32(expected)))
    read_cases='import Base\n\ndef cases() -> List<(String & (U32 & U32))>:\n  ['+',\n   '.join('("'+n+'", ('+str(size)+', '+str(crc)+'))' for n,size,crc in reads)+']\n'
    read_cases+='\ndef short_read_crc() -> U32:\n  '+str(binascii.crc32(bytes([42,43])+bytes(range(100))))+'\n'
    (FIX/'reads.bend').write_text(read_cases)
    manifest={'valid':ok,'invalid':bad,'read_regressions':reads,
              'sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(FIX.iterdir()) if p.is_file() and p.name != 'manifest.json'}}
    (FIX/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    return manifest


def run_process(output):
    """Run one process at a time with a deadline; log stdout and stderr."""
    def run(label,command,deadline):
        log=output/(label+'.log')
        start=time.monotonic()
        with open(log,'wb') as sink:
            process=subprocess.Popen(command,stdout=sink,stderr=subprocess.STDOUT)
            try:
                process.wait(timeout=max(1.0,deadline-time.monotonic()))
                cancelled=None
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                cancelled='deadline'
        return {'label':label,'exit_code':process.returncode,'cancellation_reason':cancelled,
                'log':str(log),'elapsed_seconds':round(time.monotonic()-start,6)}
    return run


def verify(decoder,output,run,real=False):
    """run(label, command, deadline) executes one process and returns its result."""
    manifest=json.loads((FIX/'manifest.json').read_text())
    ok,bad=manifest['valid'],manifest['invalid']
    deadline=time.monotonic()+120
    measurements=[]
    def decode(label,path,out):
        return run(label,[str(decoder),'--threads','2','--gpu','off',str(path),str(out)],deadline)
    def normal(r,expected):
        assert r['exit_code']==expected and r['cancellation_reason'] is None,(r['label'],r)
    for name,_ in ok:
        out=output/(name+'.rgba');r=decode('valid-'+name,FIX/(name+'.png'),out)
        normal(r,0)
        assert out.read_bytes()==(FIX/(name+'.rgba')).read_bytes(),name
    for name,expected in bad:
        out=output/(name+'-unexpected.rgba')
        r=decode('invalid-'+name,FIX/(name+'.png'),out)
        normal(r,1)
        message=Path(r['log']).read_text(errors='replace')
        assert not out.exists() and (not expected or expected in message),(name,message)
    for name in (REAL_PNGS if real else ()):
        source=Path('/usr/share/pixmaps')/(name+'.png')
        assert source.is_file(),f'Required real PNG missing: {source}'
        out=output/(name+'.rgba');r=decode('real-'+name,source,out)
        normal(r,0)
        reference=output/(name+'-reference.rgba')
        comparison=run('reference-'+name,['magick','-limit','thread','2',str(source),'-depth','8','RGBA:'+str(reference)],deadline)
        normal(comparison,0)
        assert out.read_bytes()==reference.read_bytes(),name
        measurements.append({'file':str(source),'input_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
                             'rgba_bytes':out.stat().st_size,'rgba_sha256':hashlib.sha256(out.read_bytes()).hexdigest(),
                             'elapsed_seconds_including_process_io':r['elapsed_seconds']})
    report={'valid_generated':len(ok),'invalid_rejected':len(bad),'real_pngs':measurements,
            'decoder_sha256':hashlib.sha256(Path(decoder).read_bytes()).hexdigest(),
            'comparison':'byte-for-byte; all cases retained; no signal or cancellation counts as rejection',
            'oracle_deadline_seconds':120}
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--prepare-only',action='store_true',help='regenerate fixtures; run nothing')
    mode.add_argument('--verify',metavar='DECODER',help='decoder binary built from examples/decode.bend')
    parser.add_argument('--real',action='store_true',help='also compare /usr/share/pixmaps PNGs with ImageMagick')
    parser.add_argument('--output',default=str(ROOT/'build'/'oracle'),help='new directory for outputs and logs')
    args=parser.parse_args()
    if args.prepare_only:
        manifest=prepare()
        print(json.dumps({'valid':len(manifest['valid']),'invalid':len(manifest['invalid']),
                          'file_read_regressions':len(manifest['read_regressions']),'execution':'none'}))
        return
    output=Path(args.output)
    output.mkdir(parents=True,exist_ok=False)
    report=verify(Path(args.verify),output,run_process(output),args.real)
    print(json.dumps({k:report[k] for k in ('valid_generated','invalid_rejected')}|{'real_pngs':len(report['real_pngs'])}))


if __name__=='__main__':main()
