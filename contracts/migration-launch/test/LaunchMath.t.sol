// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchMath} from "../src/LaunchMath.sol";
import {Test} from "./Base.t.sol";

/// @dev Pins the ported TickMath to Uniswap v4's published boundary values and to an independent
///      80-digit decimal evaluation of sqrt(1.0001^tick) * 2^96 for the full-range ticks at spacing 60.
contract LaunchMathTest is Test {
    function test_CanonicalBoundaries() public pure {
        assertEq(LaunchMath.sqrtPriceAtTick(-887_272), 4_295_128_739, "v4 MIN_SQRT_PRICE");
        assertEq(
            LaunchMath.sqrtPriceAtTick(887_272),
            1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342,
            "v4 MAX_SQRT_PRICE"
        );
        assertEq(LaunchMath.sqrtPriceAtTick(0), 1 << 96, "tick 0 is price 1");
    }

    function test_FullRangeAtSpacing60() public pure {
        assertEq(LaunchMath.sqrtPriceAtTick(-887_220), 4_306_310_044, "lower full-range tick");
        assertEq(
            LaunchMath.sqrtPriceAtTick(887_220),
            1_457_652_066_949_847_389_969_617_340_386_294_118_487_833_376_468,
            "upper full-range tick"
        );
        assertEq(LaunchMath.sqrtPriceAtTick(60), 79_466_191_966_197_645_195_421_774_833, "tick 60");
        assertEq(LaunchMath.sqrtPriceAtTick(-60), 78_990_846_045_029_531_151_608_375_686, "tick -60");
    }

    function test_RejectsTicksOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchMath.TickOutOfRange.selector, int24(887_273)));
        this.sqrtAt(887_273);
        vm.expectRevert(abi.encodeWithSelector(LaunchMath.TickOutOfRange.selector, int24(-887_273)));
        this.sqrtAt(-887_273);
    }

    function testFuzz_Monotonic(int24 tick) public pure {
        if (tick < -887_272 || tick >= 887_272) return;
        require(LaunchMath.sqrtPriceAtTick(tick) < LaunchMath.sqrtPriceAtTick(tick + 1), "not increasing");
    }

    function sqrtAt(int24 tick) external pure returns (uint160) {
        return LaunchMath.sqrtPriceAtTick(tick);
    }
}
