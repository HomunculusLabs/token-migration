// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev The two pieces of Uniswap v4 math the settler needs, ported so the project carries no Uniswap
///      dependency: TickMath.getSqrtPriceAtTick, with the published constants, and BalanceDelta unpacking.
///      test/LaunchMath.t.sol pins the tick math to v4's canonical boundary values.
library LaunchMath {
    int24 internal constant MAX_TICK = 887_272;

    error TickOutOfRange(int24 tick);

    function sqrtPriceAtTick(int24 tick) internal pure returns (uint160) {
        if (tick < -MAX_TICK || tick > MAX_TICK) revert TickOutOfRange(tick);
        uint256 absTick = uint256(tick < 0 ? -int256(tick) : int256(tick));
        uint256[20] memory factors = [
            uint256(0xfffcb933bd6fad37aa2d162d1a594001),
            uint256(0xfff97272373d413259a46990580e213a),
            uint256(0xfff2e50f5f656932ef12357cf3c7fdcc),
            uint256(0xffe5caca7e10e4e61c3624eaa0941cd0),
            uint256(0xffcb9843d60f6159c9db58835c926644),
            uint256(0xff973b41fa98c081472e6896dfb254c0),
            uint256(0xff2ea16466c96a3843ec78b326b52861),
            uint256(0xfe5dee046a99a2a811c461f1969c3053),
            uint256(0xfcbe86c7900a88aedcffc83b479aa3a4),
            uint256(0xf987a7253ac413176f2b074cf7815e54),
            uint256(0xf3392b0822b70005940c7a398e4b70f3),
            uint256(0xe7159475a2c29b7443b29c7fa6e889d9),
            uint256(0xd097f3bdfd2022b8845ad8f792aa5825),
            uint256(0xa9f746462d870fdf8a65dc1f90e061e5),
            uint256(0x70d869a156d2a1b890bb3df62baf32f7),
            uint256(0x31be135f97d08fd981231505542fcfa6),
            uint256(0x9aa508b5b7a84e1c677de54f3e99bc9),
            uint256(0x5d6af8dedb81196699c329225ee604),
            uint256(0x2216e584f5fa1ea926041bedfe98),
            uint256(0x48a170391f7dc42444e8fa2)
        ];
        uint256 ratio = 1 << 128;
        for (uint256 i; i < 20; ++i) {
            if ((absTick >> i) & 1 != 0) ratio = (ratio * factors[i]) >> 128;
        }
        if (tick > 0) ratio = type(uint256).max / ratio;
        // Q128.128 → Q64.96, rounding up. The result is below 2^160 for every tick in range.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    /// @dev Both halves of a BalanceDelta are int128 by construction, so the truncating casts are exact.
    function amount0(int256 delta) internal pure returns (int128) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(delta >> 128);
    }

    function amount1(int256 delta) internal pure returns (int128) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(delta);
    }
}
