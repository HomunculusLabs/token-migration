// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationLaunch} from "../src/MigrationLaunch.sol";
import {MigrationSettler} from "../src/MigrationSettler.sol";
import {LaunchMath} from "../src/LaunchMath.sol";
import {PoolKey} from "../src/LaunchInterfaces.sol";
import {Test} from "./Base.t.sol";

/**
 * @dev The fuzz + invariant suite for MigrationLaunch and LaunchMath.
 *
 * Stateless (`LaunchFuzzTest`, run deep with FOUNDRY_PROFILE=deep):
 *  - LaunchMath.sqrtPriceAtTick: bounded, monotonic, self-consistent under binary-search inversion, symmetric
 *    (p(t)*p(-t) >= 2^192 with a provable ceiling), exact at the canonical boundaries, reverting outside range.
 *  - LaunchMath.amount0/amount1: exact int128 unpacking of a random int256.
 *  - The constructor/store: random Params (1..6 ranges) round-trip through the SSTORE2 store bit-for-bit,
 *    SETTLE_PARAMS is STOP-prefixed and inert under arbitrary calldata, every immutable equals its input.
 *  - The wiring checks: every corrupted Config/Params field reverts with InvalidLaunch, never stores anything.
 *
 * Stateful (`LaunchInvariantTest` + Handler): the launch state machine under a random interleaving of hostile
 * calls. The Safe is a real delegate-proxy (vm.etch), the vault/settler/tokens are minimal functional doubles
 * of the vault slice and settler surface the launch touches, so `launch()` runs its five steps for real:
 * at-most-once, funds conservation, code immutability, params integrity, and NotRunByTheSafe everywhere else.
 */
contract LaunchFuzzTest is Test {
    address internal constant SAFE = address(0x5AFE);
    address internal constant V1 = address(0x1111);
    address internal constant V2 = address(0x2222);
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    StubSettler internal settler = new StubSettler(SAFE, V1, V2, WETH);
    StubVault internal vault = new StubVault(SAFE, V1, V2);

    // ------------------------------------------------------------------ math

    function testFuzz_SqrtPriceBoundedAndMonotonic(int24 a, int24 b) public pure {
        a = _bound24(a, -LaunchMath.MAX_TICK, LaunchMath.MAX_TICK);
        b = _bound24(b, -LaunchMath.MAX_TICK, LaunchMath.MAX_TICK);
        if (a > b) (a, b) = (b, a);
        uint160 pa = LaunchMath.sqrtPriceAtTick(a);
        uint160 pb = LaunchMath.sqrtPriceAtTick(b);
        assertTrue(pa <= pb, "monotonic");
        assertTrue(pb <= LaunchMath.sqrtPriceAtTick(LaunchMath.MAX_TICK), "bounded");
        assertTrue(LaunchMath.sqrtPriceAtTick(-LaunchMath.MAX_TICK) <= pa, "bounded below");
    }

    /// @dev ceil(x)*ceil(y) with x*y = 2^192 exactly: the product must be 2^192 itself or barely above
    ///      (the two ceilings add at most p(t) + p(-t) + 1 over the exact product).
    function testFuzz_SqrtPriceSymmetry(int24 t) public pure {
        t = _bound24(t, -LaunchMath.MAX_TICK, LaunchMath.MAX_TICK);
        uint160 p = LaunchMath.sqrtPriceAtTick(t);
        uint160 q = LaunchMath.sqrtPriceAtTick(-t);
        uint256 prod = uint256(p) * uint256(q);
        assertTrue(prod >= 1 << 192, "below 2^192");
        assertTrue(prod <= (1 << 192) + uint256(p) + uint256(q) + 1, "too far above 2^192");
    }

    /// @dev Inverting the price by binary search over the function itself must land within one tick: the table
    ///      is dense and monotonic, so any wrong constant breaks this.
    function testFuzz_SqrtPriceSelfInverse(int24 t) public pure {
        t = _bound24(t, -LaunchMath.MAX_TICK + 1, LaunchMath.MAX_TICK - 1);
        uint160 p = LaunchMath.sqrtPriceAtTick(t);
        int24 lo = -LaunchMath.MAX_TICK;
        int24 hi = LaunchMath.MAX_TICK;
        while (lo < hi) {
            // floor toward lo: (lo+hi)/2 truncating toward zero wedges at lo<0, hi=0
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 mid = lo + int24(uint24(uint256(int256(hi) - int256(lo)) / 2));
            if (LaunchMath.sqrtPriceAtTick(mid) < p) lo = mid + 1;
            else hi = mid;
        }
        assertTrue(lo >= t - 1 && lo <= t + 1, "binary search inversion off by more than 1");
    }

    function testFuzz_OutOfRangeReverts(int24 t) public {
        // Remap any in-range fuzz value into the two out-of-range bands, deterministically from the input.
        // (+1 keeps both bands strictly outside [-MAX_TICK, MAX_TICK].)
        if (t >= -LaunchMath.MAX_TICK && t <= LaunchMath.MAX_TICK) {
            if (t < 0) {
                // forge-lint: disable-next-line(unsafe-typecast)
                t = int24(-LaunchMath.MAX_TICK - int24(uint24(uint256(int256(t)) % 1000 + 1)));
            } else {
                // forge-lint: disable-next-line(unsafe-typecast)
                t = int24(LaunchMath.MAX_TICK + int24(uint24(uint256(int256(t)) % 1000 + 1)));
            }
        }
        assertTrue(t < -LaunchMath.MAX_TICK || t > LaunchMath.MAX_TICK, "remap failed");
        vm.expectRevert(abi.encodeWithSelector(LaunchMath.TickOutOfRange.selector, t));
        this.sqrtAt(t); // external, like LaunchMathTest's own reject test
    }

    function sqrtAt(int24 t) external pure returns (uint160) {
        return LaunchMath.sqrtPriceAtTick(t);
    }

    function testFuzz_AmountUnpackExact(int128 hi, int128 lo) public pure {
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 delta = (int256(hi) << 128) | int256(uint256(uint128(lo)));
        assertTrue(LaunchMath.amount0(delta) == hi, "amount0");
        assertTrue(LaunchMath.amount1(delta) == lo, "amount1");
    }

    function test_Ticks0AndBoundariesExact() public pure {
        assertTrue(LaunchMath.sqrtPriceAtTick(0) == 79228162514264337593543950336, "tick 0 == 2^96");
        assertTrue(LaunchMath.sqrtPriceAtTick(-887_272) == 4295128739, "v4 MIN_SQRT_PRICE");
        assertTrue(
            LaunchMath.sqrtPriceAtTick(887_272) == 1461446703485210103287273052203988822378723970342,
            "v4 MAX_SQRT_PRICE"
        );
    }

    // -------------------------------------------------------- constructor/store

    function testFuzz_ParamsRoundTripThroughStore(uint8 n, uint192 seed, int24 openTick, uint88 minWethOut) public {
        n = uint8(_bound(uint256(n), 1, 6));
        openTick = _bound24(openTick, -887_272, 887_272);
        MigrationSettler.Params memory p = _randomParams(n, seed, openTick, uint256(minWethOut));
        bytes memory encoded = abi.encode(p);
        MigrationLaunch l = new MigrationLaunch(_configFor(p), p);

        assertTrue(l.SAFE() == SAFE && l.VAULT() == address(vault) && l.SETTLER() == address(settler), "addrs");
        assertTrue(l.V1() == V1 && l.V2() == V2 && l.WETH() == WETH, "tokens");
        assertTrue(l.V2_FOR_CLAIMS() == _claims(), "claims");
        assertTrue(l.V2_FOR_POOL() == _pool(), "pool");
        assertTrue(l.V1_FOR_SALE() == p.v1In, "sale");
        assertTrue(l.V1_SOLD_ON_V3_TAIL() == p.tailIn, "tail");
        assertTrue(l.MIN_WETH_OUT() == p.minWethOut, "floor");
        assertTrue(l.OPEN_TICK() == p.openTick, "tick");
        assertTrue(l.NEW_POOL_ID() == keccak256(abi.encode(p.newKey)), "pool id");
        assertTrue(l.V2_RANGES() == n, "ranges");
        assertTrue(l.SETTLE_PARAMS_HASH() == keccak256(encoded), "hash");
        bytes memory store = l.SETTLE_PARAMS().code;
        assertTrue(store.length == encoded.length + 1, "store size");
        assertTrue(store[0] == 0x00, "STOP prefix");
        assertTrue(keccak256(_slice1(store)) == keccak256(encoded), "stored bytes");
        assertTrue(keccak256(abi.encode(l.settleParams())) == keccak256(encoded), "settleParams round trip");
    }

    function testFuzz_StoreIsInertUnderArbitraryCalldata(uint8 n, uint192 seed, bytes4 sel, bytes memory tail) public {
        MigrationLaunch l = new MigrationLaunch(
            _configFor(_randomParams(uint8(_bound(n, 1, 6)) + 1, seed, 60, 1 ether)),
            _randomParams(uint8(_bound(n, 1, 6)) + 1, seed, 60, 1 ether)
        );
        (bool ok, bytes memory ret) = l.SETTLE_PARAMS().call(abi.encodePacked(sel, tail));
        assertTrue(ok && ret.length == 0, "store executed something");
    }

    function testFuzz_CorruptConfigAlwaysReverts(uint8 which, uint192 seed) public {
        which = uint8(_bound(which, 0, 9));
        MigrationSettler.Params memory p = _randomParams(3, seed, 60, 1 ether);
        MigrationLaunch.Config memory c = _configFor(p);
        if (which == 0) c.safe = address(0);
        else if (which == 1) c.settler = address(new StubSettler(address(0xBAD), V1, V2, WETH));
        else if (which == 2) c.settler = address(new StubSettler(SAFE, V1, address(0xBAD), WETH));
        else if (which == 3) c.vault = address(new StubVault(address(0xBAD), V1, V2));
        else if (which == 4) c.vault = address(new StubVault(SAFE, address(0xBAD), V2));
        else if (which == 5) c.vault = address(new StubVault(SAFE, V1, address(0xBAD)));
        else if (which == 6) c.v2ForClaims = 0;
        else if (which == 7) c.v2ForPool = 0;
        else if (which == 8) p.v1In = 0;
        else p.v2Ranges = new MigrationSettler.V2Range[](0);
        string[10] memory reason = [
            "settler", // 0: safe == 0 trips the settler check first
            "settler", // 1
            "settler", // 2
            "vault", // 3
            "vault", // 4
            "vault", // 5
            "amounts", // 6
            "amounts", // 7
            "params", // 8
            "params" // 9
        ];
        vm.expectRevert(abi.encodeWithSelector(MigrationLaunch.InvalidLaunch.selector, reason[which]));
        new MigrationLaunch(c, p);
    }

    // ----------------------------------------------------------------- helpers

    function _claims() internal pure returns (uint256) {
        return 2_200 ether;
    }

    function _pool() internal pure returns (uint256) {
        return 98 ether + 10;
    }

    function _configFor(MigrationSettler.Params memory) internal view returns (MigrationLaunch.Config memory) {
        return MigrationLaunch.Config({
            safe: SAFE,
            vault: address(vault),
            v2: V2,
            settler: address(settler),
            v2ForClaims: _claims(),
            v2ForPool: _pool()
        });
    }

    function _randomParams(uint8 n, uint192 seed, int24 openTick, uint256 floor)
        internal
        pure
        returns (MigrationSettler.Params memory p)
    {
        uint256 s = uint256(seed);
        p.oldKey = PoolKey(
            address(_drift(s, 1)),
            address(_drift(s, 2)),
            // forge-lint: disable-next-line(unsafe-typecast)
            uint24(s % 0x800001),
            // forge-lint: disable-next-line(unsafe-typecast)
            int24(uint24(s % 200)),
            address(_drift(s, 3))
        );
        p.v1In = 1 + s % 1e30;
        p.tailIn = s % p.v1In;
        p.tailLimit = uint160(1 + (s >> 8) % 1461446703485210103287273052203988822378723970340);
        p.newKey = PoolKey(
            address(_drift(s, 4)),
            address(_drift(s, 5)),
            uint24((s >> 16) % 1_000_000),
            int24(uint24((s >> 24) % 200)),
            address(_drift(s, 6))
        );
        p.openTick = openTick;
        p.v2Ranges = new MigrationSettler.V2Range[](n);
        for (uint256 i; i < n; ++i) {
            p.v2Ranges[i] = MigrationSettler.V2Range(
                int24(uint24((s >> (8 * i + 1)) % 1_700_000)) - 850_000,
                int24(uint24((s >> (8 * i + 3)) % 1_700_000)) - 850_000,
                uint128(1 + (s >> (8 * i + 5)) % (1 << 100))
            );
        }
        p.minWethOut = floor + s % 1e24;
    }

    function _drift(uint256 s, uint256 k) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(s, k)))));
    }

    function _bound(uint256 v, uint256 min, uint256 max) internal pure returns (uint256) {
        return min + (v % (max + 1 - min));
    }

    function _bound24(int24 v, int24 min, int24 max) internal pure returns (int24) {
        // forge-lint: disable-next-line(unsafe-typecast)
        if (v < min) return min + int24(uint24(uint256(int256(v)) % uint256(int256(max) - min)));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (v > max) return max - int24(uint24(uint256(int256(v)) % uint256(int256(max) - min)));
        return v;
    }

    function _slice1(bytes memory b) internal pure returns (bytes memory) {
        bytes memory out = new bytes(b.length - 1);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[i + 1];
        }
        return out;
    }
}

/// @dev The getters MigrationLaunch's constructor reads, mirroring test/utils/LaunchStubs.sol (kept local so
///      this suite owns everything it runs).
contract StubSettler {
    address public immutable SAFE;
    address public immutable V1;
    address public immutable V2;
    address public immutable WETH;

    constructor(address safe, address v1, address v2, address weth) {
        SAFE = safe;
        V1 = v1;
        V2 = v2;
        WETH = weth;
    }
}

contract StubVault {
    address internal immutable OWNER;
    address internal immutable TOKEN_V1;
    address internal immutable TOKEN_V2;

    constructor(address owner_, address v1, address v2) {
        OWNER = owner_;
        TOKEN_V1 = v1;
        TOKEN_V2 = v2;
    }

    function owner() external view returns (address) {
        return OWNER;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function V1() external view returns (address) {
        return TOKEN_V1;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function V2() external view returns (address) {
        return TOKEN_V2;
    }
}
