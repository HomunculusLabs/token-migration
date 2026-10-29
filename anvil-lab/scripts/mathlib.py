#!/usr/bin/env python3
"""Offline ABI / Ethereum Keccak / integer price math.
TickMath constants derive from Uniswap v4-core (MIT); see NOTICE.md.
"""
from decimal import Decimal, localcontext
TOKEN = '0xc52aedec3374422d7510e294cfaa90799595cba3'
WETH = '0x4200000000000000000000000000000000000006'
POOL_ID = '0xfc25fdd217e288d03a877f0b7d49e0bbe52b2288c88de929125062569fc7eb2a'
MANAGER = '0x498581ff718922c3f8e6a244956af099b2652b2b'
STATE_VIEW = '0xa3c0c9b65bad0b08107aa264b0f3db444b867a71'
QUOTER = '0x0d5e0f971ed27fbff6c2837bf31316121532048d'
POSITION_MANAGER = '0x7c5f5a4bbd8fd63184577525326123b519429bdc'
Q96 = 1 << 96
MIN_TICK, MAX_TICK = -887272, 887272
U256 = (1 << 256) - 1
MASK64 = (1 << 64) - 1

# Keccak-256 (Ethereum variant, NOT hashlib.sha3_256).
RC = [0x1,0x8082,0x800000000000808a,0x8000000080008000,0x808b,
      0x80000001,0x8000000080008081,0x8000000000008009,0x8a,0x88,
      0x80008009,0x8000000a,0x8000808b,0x800000000000008b,
      0x8000000000008089,0x8000000000008003,0x8000000000008002,
      0x8000000000000080,0x800a,0x800000008000000a,
      0x8000000080008081,0x8000000000008080,0x80000001,
      0x8000000080008008]
ROT = [0,1,62,28,27,36,44,6,55,20,3,10,43,25,39,41,45,15,21,8,18,2,61,56,14]

def rol(x: int, n: int) -> int:
    return ((x << n) | (x >> ((64 - n) % 64))) & MASK64

def keccak256(data: bytes) -> bytes:
    rate = 136
    padded = bytearray(data)
    pad_length = rate - len(padded) % rate
    if pad_length == 1:
        padded.append(0x81)
    else:
        padded.append(1)
        padded.extend(b'\0' * (pad_length - 2))
        padded.append(0x80)
    a = [0] * 25
    for p in range(0, len(padded), rate):
        block = padded[p:p + rate]
        for i in range(rate // 8):
            a[i] ^= int.from_bytes(block[8*i:8*i+8], 'little')
        for rc in RC:
            c = [a[x] ^ a[x+5] ^ a[x+10] ^ a[x+15] ^ a[x+20] for x in range(5)]
            d = [c[(x-1)%5] ^ rol(c[(x+1)%5], 1) for x in range(5)]
            for y in range(5):
                for x in range(5):
                    a[x+5*y] ^= d[x]
            b = [0] * 25
            for y in range(5):
                for x in range(5):
                    b[y + 5*((2*x+3*y)%5)] = rol(a[x+5*y], ROT[x+5*y])
            for y in range(5):
                for x in range(5):
                    a[x+5*y] = b[x+5*y] ^ ((~b[(x+1)%5+5*y]) & b[(x+2)%5+5*y])
            a[0] ^= rc
    return b''.join(x.to_bytes(8, 'little') for x in a)[:32]

def word(x: int | str) -> bytes:
    if isinstance(x, str):
        x = int(x, 16)
    if not -(1 << 255) <= x <= U256:
        raise ValueError('ABI word out of range')
    return (x & U256).to_bytes(32, 'big')

def calldata(signature: str, args: list[int | str]) -> str:
    return '0x' + (keccak256(signature.encode())[:4] + b''.join(word(x) for x in args)).hex()

def words(data: str) -> list[int]:
    raw = bytes.fromhex(data.removeprefix('0x'))
    if len(raw) % 32:
        raise ValueError('Return data is not ABI-word aligned')
    return [int.from_bytes(raw[i:i+32], 'big') for i in range(0, len(raw), 32)]

def signed(x: int, bits: int) -> int:
    v = x & ((1 << bits)-1)
    return v - (1 << bits) if v >= 1 << (bits-1) else v

def address(x: int) -> str:
    if not 0 <= x < (1 << 160):
        raise ValueError('Invalid ABI address')
    return f'0x{x:040x}'

def units(n: int, decimals: int = 18) -> str:
    negative = n < 0
    n = abs(n)
    integer, fraction = divmod(n, 10 ** decimals)
    s = str(integer)
    if fraction:
        s += '.' + str(fraction).zfill(decimals).rstrip('0')
    return ('-' if negative else '') + s

def parse_units(value: str, decimals: int) -> int:
    with localcontext() as ctx:
        ctx.prec = 120
        n = Decimal(value) * Decimal(10) ** decimals
        if not n.is_finite() or n <= 0 or n != n.to_integral_value():
            raise ValueError('Token quantities must be positive and exactly representable')
        return int(n)

# Mathematical constants/rounding follow Uniswap TickMath (MIT; see SOURCES.md).
TICK_FACTORS = [int(s,16) for s in [
 'fffcb933bd6fad37aa2d162d1a594001','fff97272373d413259a46990580e213a',
 'fff2e50f5f656932ef12357cf3c7fdcc','ffe5caca7e10e4e61c3624eaa0941cd0',
 'ffcb9843d60f6159c9db58835c926644','ff973b41fa98c081472e6896dfb254c0',
 'ff2ea16466c96a3843ec78b326b52861','fe5dee046a99a2a811c461f1969c3053',
 'fcbe86c7900a88aedcffc83b479aa3a4','f987a7253ac413176f2b074cf7815e54',
 'f3392b0822b70005940c7a398e4b70f3','e7159475a2c29b7443b29c7fa6e889d9',
 'd097f3bdfd2022b8845ad8f792aa5825','a9f746462d870fdf8a65dc1f90e061e5',
 '70d869a156d2a1b890bb3df62baf32f7','31be135f97d08fd981231505542fcfa6',
 '9aa508b5b7a84e1c677de54f3e99bc9','5d6af8dedb81196699c329225ee604',
 '2216e584f5fa1ea926041bedfe98','48a170391f7dc42444e8fa2']]

def sqrt_at_tick(tick: int) -> int:
    if not MIN_TICK <= tick <= MAX_TICK:
        raise ValueError('Tick outside Uniswap range')
    ratio = 1 << 128
    for i, factor in enumerate(TICK_FACTORS):
        if abs(tick) & (1 << i):
            ratio = (ratio * factor) >> 128
    if tick > 0:
        ratio = U256 // ratio
    return (ratio + (1 << 32) - 1) >> 32

def interval_amounts(lo: int, hi: int, liquidity: int, sqrt_price: int) -> tuple[int, int]:
    a, b = sqrt_at_tick(lo), sqrt_at_tick(hi)
    s = max(a, min(sqrt_price, b))
    amount0 = liquidity * Q96 * (b-s) // (b*s)
    amount1 = liquidity * (s-a) // Q96
    return amount0, amount1

def reconstruct(ticks: list[dict], sqrt_price: int, current_tick: int, active: int) -> tuple[list[dict], int, int]:
    rows, running, current, a0, a1 = [], 0, 0, 0, 0
    # Net-zero boundaries do not change the core liquidity curve.
    relevant = [t for t in ticks if int(t['liquidityNet']) != 0]
    for i, t in enumerate(relevant):
        running += int(t['liquidityNet'])
        if not 0 <= running < 1 << 128:
            raise RuntimeError('Invalid cumulative liquidity; refusing to publish reserves')
        if i + 1 == len(relevant):
            break
        lo, hi = t['tick'], relevant[i+1]['tick']
        if lo <= current_tick < hi:
            current = running
        if running:
            x, y = interval_amounts(lo, hi, running, sqrt_price)
            rows.append({'tickLower': lo, 'tickUpper': hi, 'liquidity': str(running),
                         'amount0_raw': str(x), 'amount1_raw': str(y)})
            a0 += x
            a1 += y
    if running != 0 or current != active:
        raise RuntimeError('Tick reconstruction does not reconcile with active liquidity')
    return rows, a0, a1

