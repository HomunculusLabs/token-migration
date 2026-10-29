#!/usr/bin/env python3.14
"""Launch kit: the successor pool's split seed (SUR-658, decided by Bill 2026-10-25).

The successor pool opens with two single-sided sides that meet at the opening tick:
    - openTick: v1's pre-sale tick on the old Doppler pool, rounded half up to the successor's tick grid (the
      old pool quotes v1 per WETH; when v2 sorts before WETH the successor quotes the inverse, so the tick is negated);
    - the v2 side: the v1 the old pool holds above its price, copied as v2 range by range. The old pool's liquidity
      is read from PoolManager storage, adjacent segments within seed.mergeBps of the block's first segment merge,
      every boundary is rounded to the successor grid, the block nearest the price ends at the seam, and each range's
      liquidity is the largest its block's v1 pays for (one exact floor);
    - the WETH side: built by the settler itself, from the opening tick to the end of the range, from what the sale
      raised.

test/utils/LadderMirror.sol builds the same ranges independently in Solidity, and the fork suite checks them on
chain; any change here must change both. Nothing in this module signs or sends anything: it reads storage.
"""
from __future__ import annotations

import kitlib as k

POOLS_SLOT = 6  # v4 PoolManager: mapping(PoolId => Pool.State) _pools
LIQUIDITY_OFFSET = 3
TICKS_OFFSET = 4
BITMAP_OFFSET = 5
Q96 = 1 << 96
MAX_TICK = 887_272
DECIDED = {"openTick": "pre-sale-tick-rounded", "v2Side": "old-pool-ladder-copy", "wethSide": "full-range"}

# v4 TickMath.getSqrtPriceAtTick (the same constants as src/LaunchMath.sol).
_FACTORS = [
    0xfffcb933bd6fad37aa2d162d1a594001, 0xfff97272373d413259a46990580e213a, 0xfff2e50f5f656932ef12357cf3c7fdcc,
    0xffe5caca7e10e4e61c3624eaa0941cd0, 0xffcb9843d60f6159c9db58835c926644, 0xff973b41fa98c081472e6896dfb254c0,
    0xff2ea16466c96a3843ec78b326b52861, 0xfe5dee046a99a2a811c461f1969c3053, 0xfcbe86c7900a88aedcffc83b479aa3a4,
    0xf987a7253ac413176f2b074cf7815e54, 0xf3392b0822b70005940c7a398e4b70f3, 0xe7159475a2c29b7443b29c7fa6e889d9,
    0xd097f3bdfd2022b8845ad8f792aa5825, 0xa9f746462d870fdf8a65dc1f90e061e5, 0x70d869a156d2a1b890bb3df62baf32f7,
    0x31be135f97d08fd981231505542fcfa6, 0x9aa508b5b7a84e1c677de54f3e99bc9, 0x5d6af8dedb81196699c329225ee604,
    0x2216e584f5fa1ea926041bedfe98, 0x48a170391f7dc42444e8fa2,
]


def sqrt_at(tick: int) -> int:
    if not -MAX_TICK <= tick <= MAX_TICK:
        k.fail(f"tick {tick} is outside v4's range")
    ratio = 1 << 128
    for i, factor in enumerate(_FACTORS):
        if abs(tick) >> i & 1:
            ratio = ratio * factor >> 128
    if tick > 0:
        ratio = ((1 << 256) - 1) // ratio
    return (ratio >> 32) + (0 if ratio % (1 << 32) == 0 else 1)


def to_grid(tick: int, spacing: int) -> int:
    """Half-up rounding to a multiple of spacing (Python's // floors, as LadderMirror._floorDiv does)."""
    return (tick + spacing // 2) // spacing * spacing


def edge(spacing: int) -> int:
    """The largest usable tick at this spacing; the smallest is its negative."""
    return MAX_TICK - MAX_TICK % spacing


def _signed(value: int, bits: int) -> int:
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def _word(value: int) -> bytes:
    return k.word(value % (1 << 256))


def _extsload(rpc: k.Rpc, pool_manager: str, slot: bytes) -> int:
    data = "0x" + (k.selector("extsload(bytes32)") + slot).hex()
    return int(rpc.eth_call(pool_manager, data), 16)


def read_ladder(rpc: k.Rpc, pool_manager: str, pool_id: bytes, spacing: int) -> dict:
    """slot0, the active liquidity, and every initialized tick with its liquidityNet, from PoolManager storage."""
    state = k.keccak(pool_id + k.word(POOLS_SLOT))
    base = int.from_bytes(state, "big")
    slot0 = _extsload(rpc, pool_manager, state)
    active = _extsload(rpc, pool_manager, k.word(base + LIQUIDITY_OFFSET)) & ((1 << 128) - 1)
    ticks = []
    for w in range((-MAX_TICK // spacing) >> 8, ((MAX_TICK // spacing) >> 8) + 1):
        bits = _extsload(rpc, pool_manager, k.keccak(_word(w) + k.word(base + BITMAP_OFFSET)))
        for bit in range(256):
            if bits >> bit & 1:
                tick = (w * 256 + bit) * spacing
                info = _extsload(rpc, pool_manager, k.keccak(_word(tick) + k.word(base + TICKS_OFFSET)))
                ticks.append((tick, _signed(info >> 128, 128)))
    return {"sqrtPriceX96": slot0 & ((1 << 160) - 1), "tick": _signed(slot0 >> 160, 24), "liquidity": active,
            "ticks": ticks}


def ladder_blocks(ladder: dict, merge_bps: int) -> tuple[list[dict], int]:
    """The v1 below the old pool's price (WETH/v1, so v1 sits at lower ticks), merged into blocks. Also checks the
    walk: the segment holding the price must carry exactly the pool's active liquidity."""
    sqrt_p, ticks = ladder["sqrtPriceX96"], ladder["ticks"]
    blocks: list[dict] = []
    liquidity, gap, total, walked = 0, True, 0, None
    for i in range(len(ticks) - 1):
        liquidity += ticks[i][1]
        if ticks[i][0] <= ladder["tick"] < ticks[i + 1][0]:
            walked = liquidity
        lower = sqrt_at(ticks[i][0])
        if lower >= sqrt_p:
            continue  # holds no v1; keep walking only to check the active liquidity
        if liquidity <= 0:
            gap = True
            continue
        upper = sqrt_at(ticks[i + 1][0])
        amount = liquidity * (min(upper, sqrt_p) - lower) // Q96
        total += amount
        if blocks and not gap and abs(liquidity - blocks[-1]["refLiquidity"]) * 10_000 <= (
                blocks[-1]["refLiquidity"] * merge_bps):
            blocks[-1]["upper"] = ticks[i + 1][0]
            blocks[-1]["amount"] += amount
        else:
            blocks.append({"lower": ticks[i][0], "upper": ticks[i + 1][0], "refLiquidity": liquidity,
                           "amount": amount})
        gap = False
    if walked is not None and walked != ladder["liquidity"]:
        k.fail(f"old pool ladder walk gives {walked} liquidity at the price, the pool says {ladder['liquidity']}")
    if not blocks:
        k.fail("the old pool holds no v1 above its price: there is nothing to copy")
    if blocks[-1]["upper"] <= ladder["tick"]:
        # Ending the copy at the opening tick would then move v1 toward the price instead of copying it.
        k.fail(f"the old pool holds no v1 at its price (its v1 stops at tick {blocks[-1]['upper']}, the price is at "
               f"{ladder['tick']}): the copy cannot meet the opening tick, so decide the seed by hand")
    return blocks, total


def v2_ranges(blocks: list[dict], seam_old: int, spacing: int, v2_first: bool) -> list[dict]:
    """The blocks on the successor grid and orientation, each sized to hold exactly its v1 as v2 (one floor)."""
    e = edge(spacing)
    ranges = []
    for j, b in enumerate(blocks):
        lo = max(-e, min(e, to_grid(b["lower"], spacing)))
        hi = seam_old if j == len(blocks) - 1 else max(-e, min(e, to_grid(b["upper"], spacing)))
        if lo >= hi:
            k.fail(f"copied block {j} [{b['lower']}, {b['upper']}] collapses on the {spacing}-tick grid: "
                   "raise seed.mergeBps")
        a, c = (-hi, -lo) if v2_first else (lo, hi)
        sa, sc = sqrt_at(a), sqrt_at(c)
        # v2 as currency0 sits above the price: amount0 = L * 2^96 * (sc - sa) / (sa * sc); as currency1 below it:
        # amount1 = L * (sc - sa) / 2^96.
        liquidity = b["amount"] * sa * sc // (Q96 * (sc - sa)) if v2_first else b["amount"] * Q96 // (sc - sa)
        if not 0 < liquidity < 1 << 128:
            k.fail(f"copied block {j} sizes to liquidity {liquidity}")
        ranges.append({"tickLower": a, "tickUpper": c, "liquidity": liquidity})
    return ranges


def v2_need(ranges: list[dict], v2_first: bool) -> int:
    """What the PositionManager takes for the v2 side: v4 SqrtPriceMath amounts rounded up (the settler's check)."""
    need = 0
    for r in ranges:
        a, b = sqrt_at(r["tickLower"]), sqrt_at(r["tickUpper"])
        if v2_first:
            need += -(-(-(-(r["liquidity"] << 96) * (b - a) // b)) // a)
        else:
            need += -(-r["liquidity"] * (b - a) // Q96)
    return need


def copy_slack(ranges: list[dict], v2_first: bool) -> int:
    """How far the v2 side may fall short of the v1 it copies: one unit of liquidity per range, plus rounding."""
    return sum(v2_need([r | {"liquidity": 1}], v2_first) + 1 for r in ranges)


def build(rpc: k.Rpc, params: dict, v2_first: bool) -> dict:
    """The signed seed for the current fork state: opening tick, v2 ranges, and what they copy."""
    seed = params["seed"]
    for key, value in DECIDED.items():
        if seed.get(key) != value:
            k.fail(f"params seed.{key} = {seed.get(key)!r}; this kit implements {value!r}")
    ext, pool = params["external"], params["successorPool"]
    old = ext["oldPool"]
    ladder = read_ladder(rpc, ext["poolManager"], bytes.fromhex(old["poolId"][2:]), old["tickSpacing"])
    if ladder["sqrtPriceX96"] == 0:
        k.fail("the old pool is not initialized on this fork")
    blocks, v1_above = ladder_blocks(ladder, seed["mergeBps"])
    seam_old = to_grid(ladder["tick"], pool["tickSpacing"])
    ranges = v2_ranges(blocks, seam_old, pool["tickSpacing"], v2_first)
    e = edge(pool["tickSpacing"])
    return {
        "oldSqrtPriceX96": ladder["sqrtPriceX96"], "oldTick": ladder["tick"], "seamOld": seam_old,
        "openTick": -seam_old if v2_first else seam_old, "v2Ranges": ranges, "v1AboveOldPrice": v1_above,
        "v2Need": v2_need(ranges, v2_first), "copySlack": copy_slack(ranges, v2_first),
        "wethSide": {"tickLower": -e, "tickUpper": -seam_old} if v2_first else {"tickLower": seam_old, "tickUpper": e},
        "blocks": [{"lower": b["lower"], "upper": b["upper"], "v1": str(b["amount"])} for b in blocks],
    }
