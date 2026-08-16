"""Streaming reader for the SingleStepTests m68000 vectors.

The binary format is documented by decode.py in the test repository; this is the
same decode without the JSON round trip, so a sweep does not need gigabytes of
scratch space.

Each test is a dict:

  name          the opcode and operands, as text
  initial/final each a dict of d0..d7, a0..a6, usp, ssp, sr, pc, plus
                'prefetch' (two words) and 'ram' (a list of [addr, byte])
  transactions  a list of bus events, in order:
                  ['n', cycles]                                    idle
                  [kind, cycles, fc, addr, size, data, uds, lds]   a transfer
                where kind is 'r' read, 'w' write, 't' a TAS cycle, and
                're'/'we' an address error, which the real part does not put on
                the bus at all -- AS is never asserted -- but which the
                generator records so the error can be recognised.
  length        total cycles

The vectors were generated from MAME's microcoded MC68000 core, so they are an
MC68000 reference and not an MC68010 one. The divergences are catalogued in
divergences.py; nothing here filters anything.
"""

import os
import struct

MAGIC_FILE = 0x1A3F5D71
MAGIC_TEST = 0xABC12367
MAGIC_NAME = 0x89ABCDEF
MAGIC_STATE = 0x01234567
MAGIC_TRANS = 0x456789AB

REG_ORDER = ['d0', 'd1', 'd2', 'd3', 'd4', 'd5', 'd6', 'd7',
             'a0', 'a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'usp',
             'ssp', 'sr', 'pc']

KINDS = {0: 'n', 1: 'w', 2: 'r', 3: 't', 4: 're', 5: 'we'}


def _name(buf, p):
    _, magic = struct.unpack_from('<II', buf, p)
    assert magic == MAGIC_NAME, hex(magic)
    p += 8
    n = struct.unpack_from('<I', buf, p)[0]
    p += 4
    s = struct.unpack_from('%ds' % n, buf, p)[0].decode('utf-8')
    return p + n, s


def _state(buf, p):
    st = {}
    _, magic = struct.unpack_from('<II', buf, p)
    assert magic == MAGIC_STATE, hex(magic)
    p += 8
    for r in REG_ORDER:
        st[r] = struct.unpack_from('<I', buf, p)[0]
        p += 4
    st['prefetch'] = list(struct.unpack_from('<II', buf, p))
    p += 8
    nram = struct.unpack_from('<I', buf, p)[0]
    p += 4
    ram = []
    for _ in range(nram):
        addr, data = struct.unpack_from('<IH', buf, p)
        p += 6
        ram.append([addr, data >> 8])
        ram.append([addr | 1, data & 0xFF])
    st['ram'] = ram
    return p, st


def _transactions(buf, p):
    _, magic = struct.unpack_from('<II', buf, p)
    assert magic == MAGIC_TRANS, hex(magic)
    p += 8
    ncyc, ntrans = struct.unpack_from('<II', buf, p)
    p += 8
    out = []
    for _ in range(ntrans):
        kind, cycles = struct.unpack_from('<BI', buf, p)
        p += 5
        if kind == 0:
            out.append(['n', cycles])
            continue
        fc, addr, data, uds, lds = struct.unpack_from('<IIIII', buf, p)
        p += 20
        out.append([KINDS[kind], cycles, fc, addr,
                    '.w' if uds + lds == 2 else '.b', data, uds, lds])
    return p, out, ncyc


def read_file(path):
    """Yield every test in one .json.bin file."""
    with open(path, 'rb') as f:
        buf = f.read()
    magic, ntests = struct.unpack_from('<II', buf, 0)
    assert magic == MAGIC_FILE, hex(magic)
    p = 8
    for _ in range(ntests):
        _, magic = struct.unpack_from('<II', buf, p)
        assert magic == MAGIC_TEST, hex(magic)
        p += 8
        p, name = _name(buf, p)
        p, initial = _state(buf, p)
        p, final = _state(buf, p)
        p, trans, ncyc = _transactions(buf, p)
        yield {'name': name, 'initial': initial, 'final': final,
               'transactions': trans, 'length': ncyc}


def vector_dir():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, '..', '..',
                        'Inputs', 'tests', 'SingleStepTests_m68000', 'v1')


def read_opcode(name):
    """read_opcode('NOP') -> iterator over that file's tests."""
    return read_file(os.path.join(vector_dir(), name + '.json.bin'))
