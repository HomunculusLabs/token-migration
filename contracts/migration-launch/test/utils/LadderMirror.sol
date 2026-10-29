// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {LaunchMath} from "../../src/LaunchMath.sol";
import {MigrationSettler} from "../../src/MigrationSettler.sol";

interface IExtsloadView {
    function extsload(bytes32 slot) external view returns (bytes32);
}

/**
 * @dev The settler's v2 side, built in Solidity independently of the kit (kit/safe_txs.py builds the same ranges in
 *      Python; the rehearsal compares the two). It reads the old pool's v1 ladder from PoolManager storage and copies
 *      the v1 the pool holds above its price as v2:
 *      1. Walk the initialized ticks from the bottom, summing liquidityNet. The old pool is WETH/v1, so its v1 sits
 *         in the segments below the current tick (the one holding the price only up to the price).
 *      2. Merge adjacent segments whose liquidity is within `mergeBps` of the block's first segment. A segment with
 *         no liquidity is a gap and is never merged across.
 *      3. Round every boundary to the successor's grid, half up. The block nearest the price ends at the seam, so the
 *         v2 side meets the WETH side at the opening tick.
 *      4. Size each block's liquidity to hold exactly the block's v1 over its rounded range (rounding down), and
 *         negate the ticks when v2 sorts before WETH (the successor then quotes the inverse price).
 */
library LadderMirror {
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 internal constant POOLS_SLOT = 6;
    uint256 internal constant TICKS_OFFSET = 4;
    uint256 internal constant BITMAP_OFFSET = 5;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant MAX_INITIALIZED_TICKS = 4096;

    struct Block {
        int24 lower;
        int24 upper;
        uint256 refLiquidity;
        uint256 amount;
    }

    /// @return ranges the successor's v2 ranges, deepest first
    /// @return v1Total the v1 the old pool holds above its price, which the ranges copy
    function mirror(
        address pm,
        bytes32 oldPoolId,
        int24 oldSpacing,
        int24 newSpacing,
        int24 seamOld,
        bool v2First,
        uint256 mergeBps
    ) internal view returns (MigrationSettler.V2Range[] memory ranges, uint256 v1Total) {
        Block[] memory blocks;
        (blocks, v1Total) = ladderBlocks(pm, oldPoolId, oldSpacing, mergeBps);
        ranges = new MigrationSettler.V2Range[](blocks.length);
        int24 edge = LaunchMath.MAX_TICK - LaunchMath.MAX_TICK % newSpacing;
        for (uint256 j; j < blocks.length; ++j) {
            int24 lo = _clamp(toGrid(blocks[j].lower, newSpacing), edge);
            int24 hi = j + 1 == blocks.length ? seamOld : _clamp(toGrid(blocks[j].upper, newSpacing), edge);
            require(lo < hi, "a copied block collapsed on the successor grid");
            (int24 a, int24 b) = v2First ? (-hi, -lo) : (lo, hi);
            uint256 sa = LaunchMath.sqrtPriceAtTick(a);
            uint256 sb = LaunchMath.sqrtPriceAtTick(b);
            // v2 as currency0 sits above the price: amount0 = L * 2^96 * (sb - sa) / (sa * sb); as currency1 below it:
            // amount1 = L * (sb - sa) / 2^96. Solved for L with one exact floor (the kit computes the same integer), so
            // a range never needs more than its block. sa * sb fits a word for any range on the v2 side here (both
            // prices sit below 2^128); checked arithmetic stops the helper otherwise.
            uint256 l = v2First
                ? Math.mulDiv(blocks[j].amount, sa * sb, Q96 * (sb - sa))
                : Math.mulDiv(blocks[j].amount, Q96, sb - sa);
            ranges[j] = MigrationSettler.V2Range(a, b, l.toUint128());
        }
    }

    /// @dev Steps 1 and 2: the old pool's v1 ladder below its price, merged into blocks, in the old orientation.
    function ladderBlocks(address pm, bytes32 poolId, int24 spacing, uint256 mergeBps)
        internal
        view
        returns (Block[] memory blocks, uint256 v1Total)
    {
        (uint160 sqrtP,) = slot0(pm, poolId);
        int24[] memory ticks = initializedTicks(pm, poolId, spacing);
        blocks = new Block[](ticks.length);
        uint256 n;
        int256 liq;
        bool gap = true;
        for (uint256 i; i + 1 < ticks.length; ++i) {
            liq += liquidityNet(pm, poolId, ticks[i]);
            uint160 lower = LaunchMath.sqrtPriceAtTick(ticks[i]);
            if (lower >= sqrtP) break; // this segment and every one above it hold no v1
            if (liq <= 0) {
                gap = true;
                continue;
            }
            uint160 upper = LaunchMath.sqrtPriceAtTick(ticks[i + 1]);
            uint256 l = liq.toUint256();
            uint256 amount = Math.mulDiv(l, (upper > sqrtP ? sqrtP : upper) - lower, Q96);
            v1Total += amount;
            if (n != 0 && !gap && _within(l, blocks[n - 1].refLiquidity, mergeBps)) {
                blocks[n - 1].upper = ticks[i + 1];
                blocks[n - 1].amount += amount;
            } else {
                blocks[n++] = Block(ticks[i], ticks[i + 1], l, amount);
            }
            gap = false;
        }
        assembly ("memory-safe") {
            mstore(blocks, n)
        }
        require(n != 0, "the old pool holds no v1 above its price");
        // Ending the copy at the opening tick would otherwise move v1 toward the price instead of copying it.
        (, int24 tick) = slot0(pm, poolId);
        require(blocks[n - 1].upper > tick, "the old pool holds no v1 at its price");
    }

    /// @dev Half-up rounding to a multiple of `spacing`.
    function toGrid(int24 tick, int24 spacing) internal pure returns (int24) {
        int256 s = spacing;
        return (_floorDiv(int256(tick) + s / 2, s) * s).toInt24();
    }

    function slot0(address pm, bytes32 poolId) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        uint256 word = uint256(IExtsloadView(pm).extsload(_stateSlot(poolId)));
        // slot0 packs sqrtPriceX96 (bits 0-159) | tick (160-183) | protocolFee | lpFee; both casts truncate on purpose.
        // forge-lint: disable-next-line(unsafe-typecast)
        sqrtPriceX96 = uint160(word);
        // forge-lint: disable-next-line(unsafe-typecast)
        tick = int24(uint24(word >> 160));
    }

    function initializedTicks(address pm, bytes32 poolId, int24 spacing) internal view returns (int24[] memory ticks) {
        bytes32 bitmap = bytes32(uint256(_stateSlot(poolId)) + BITMAP_OFFSET);
        int256 minWord = _floorDiv(_floorDiv(-int256(LaunchMath.MAX_TICK), spacing), 256);
        int256 maxWord = _floorDiv(_floorDiv(int256(LaunchMath.MAX_TICK), spacing), 256);
        ticks = new int24[](MAX_INITIALIZED_TICKS);
        uint256 n;
        for (int256 w = minWord; w <= maxWord; ++w) {
            uint256 bits = uint256(IExtsloadView(pm).extsload(keccak256(abi.encode(w, bitmap))));
            for (uint256 bit; bits != 0 && bit < 256; ++bit) {
                if ((bits >> bit) & 1 == 0) continue;
                require(n < MAX_INITIALIZED_TICKS, "more initialized ticks than the reader holds");
                // forge-lint: disable-next-line(unsafe-typecast)
                ticks[n++] = ((w * 256 + int256(bit)) * spacing).toInt24();
            }
        }
        assembly ("memory-safe") {
            mstore(ticks, n)
        }
    }

    function liquidityNet(address pm, bytes32 poolId, int24 tick) internal view returns (int256) {
        bytes32 ticksSlot = bytes32(uint256(_stateSlot(poolId)) + TICKS_OFFSET);
        uint256 word = uint256(IExtsloadView(pm).extsload(keccak256(abi.encode(int256(tick), ticksSlot))));
        // TickInfo's first word packs liquidityGross (low 128 bits) | liquidityNet (high 128 bits, signed).
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(word) >> 128;
    }

    function _stateSlot(bytes32 poolId) private pure returns (bytes32) {
        return keccak256(abi.encode(poolId, POOLS_SLOT));
    }

    function _within(uint256 l, uint256 ref, uint256 bps) private pure returns (bool) {
        uint256 diff = l > ref ? l - ref : ref - l;
        return diff * 10_000 <= ref * bps;
    }

    function _clamp(int24 tick, int24 edge) private pure returns (int24) {
        return tick < -edge ? -edge : (tick > edge ? edge : tick);
    }

    function _floorDiv(int256 a, int256 b) private pure returns (int256 q) {
        q = a / b;
        if (a % b != 0 && (a < 0) != (b < 0)) q -= 1;
    }
}
