// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SurplusPoolHook} from "../../src/SurplusPoolHook.sol";
import {BalanceDeltaLib, IPoolManager, ModifyLiquidityParams, PoolKey, SwapParams} from "../../src/V4Minimal.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {MockERC20} from "../MockERC20.sol";
import {HookTest} from "../utils/HookTest.sol";
import {Actor, IPoolManagerErrors} from "./Actor.sol";

interface IWETH9 {
    function deposit() external payable;
}

/**
 * @dev Fork harness against the REAL Base PoolManager at a pinned block. The hook is deployed through the live
 *      CREATE2 proxy at a mined salt. The official pool (v2/WETH, 1.2% LP fee, tick spacing 60, the hook) is
 *      compared against a hookless twin: same currencies, fee, spacing, price and liquidity. A hook that is only
 *      called at initialization cannot change pool math, so every swap on the official pool must return exactly
 *      what the same swap returns on the twin, and the two pools stay in lockstep across consecutive swaps.
 *
 *      v2 is a mock placed below or above WETH (`_v2IsCurrency0`), so both currency orders run against the real
 *      manager. Only runs against a fork (the project's Nx `fork` target); without one every suite skips.
 */
abstract contract ForkHarness is HookTest {
    using BalanceDeltaLib for int256;

    IPoolManager internal constant MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant PINNED_BLOCK = 51_935_583;

    uint24 internal constant LP_FEE = 12_000; // pips: 1.2%, restated independently of the kit
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant PIPS = 1_000_000;

    // TickMath.MIN_SQRT_PRICE + 1 and MAX_SQRT_PRICE - 1: no price limit in either direction.
    uint160 internal constant NO_LIMIT_ZERO_FOR_ONE = 4_295_128_740;
    uint160 internal constant NO_LIMIT_ONE_FOR_ZERO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    // v2 starts at 25,000 per WETH. Any price works; a non-unit one keeps a mixed-up currency from passing as a
    // near-equal amount.
    uint256 internal constant V2_PER_WETH = 25_000;
    int24 internal constant HALF_RANGE = 6000; // ticks either side of the start price, a multiple of the spacing
    int256 internal constant LIQUIDITY = 1e24; // ~1,640 WETH + ~41M v2 per pool

    // A POOLS_SLOT entry's first word is slot0 (v4-core StateLibrary): sqrtPriceX96 in the low 160 bits.
    uint256 internal constant POOLS_SLOT = 6;

    address internal constant INITIALIZER = address(0x1417); // stands in for the launch helper
    address internal constant STRANGER = address(0xBAD);

    MockERC20 internal v2;
    Actor internal actor;
    SurplusPoolHook internal hook;
    PoolKey internal official;
    PoolKey internal twin;
    // The seeded position's range, the same in both pools: they open at the same price.
    int24 internal lower;
    int24 internal upper;

    function _v2IsCurrency0() internal pure virtual returns (bool);

    function setUp() public virtual {
        // vm.skip halts setUp, so nothing below runs without a fork.
        if (!_forked()) vm.skip(true, "fork suite: run the project's Nx `fork` target");
        assertEq(block.chainid, BASE_CHAIN_ID, "fork is not Base");
        assertEq(block.number, vm.envOr("FORK_BLOCK", PINNED_BLOCK), "fork is not at the pinned block");
        assertGt(address(MANAGER).code.length, 0, "no PoolManager at the pinned block");

        v2 = MockERC20(_v2Address());
        vm.etch(address(v2), vm.getDeployedCode("MockERC20.sol:MockERC20"));
        (address c0, address c1) = _v2IsCurrency0() ? (address(v2), WETH) : (WETH, address(v2));
        hook = _deployHookViaCreate2(HookArgs(address(MANAGER), INITIALIZER, c0, c1, LP_FEE, TICK_SPACING));
        official = PoolKey(c0, c1, LP_FEE, TICK_SPACING, address(hook));
        twin = PoolKey(c0, c1, LP_FEE, TICK_SPACING, address(0));

        actor = new Actor(MANAGER);
        vm.deal(address(this), 10_000 ether);
        IWETH9(WETH).deposit{value: 10_000 ether}();
        assertTrue(IERC20(WETH).transfer(address(actor), 10_000 ether), "fund actor WETH");
        v2.mint(address(actor), 1e9 ether);

        vm.label(address(MANAGER), "PoolManager");
        vm.label(WETH, "WETH");
        vm.label(address(v2), "v2");
        vm.label(address(actor), "actor");
    }

    function _forked() internal view returns (bool) {
        try vm.activeFork() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Deploys the hook the way production does: CREATE2 through Arachnid's proxy, live on Base, at the
    ///      smallest salt that gives the address exactly the hook's flag bits.
    function _deployHookViaCreate2(HookArgs memory a) internal returns (SurplusPoolHook) {
        address deployer = HookMiner.CREATE2_DEPLOYER;
        assertGt(deployer.code.length, 0, "CREATE2 proxy is live at the pinned block");
        bytes memory initCode = _hookInitCode(a);
        (bytes32 salt, address predicted) =
            HookMiner.find(deployer, keccak256(initCode), _declaredFlags(), 0, HookMiner.MAX_ITERATIONS);
        (bool ok, bytes memory ret) = deployer.call(abi.encodePacked(salt, initCode));
        assertTrue(ok && ret.length == 20, "CREATE2 deploy through the proxy");
        // Exactly 20 bytes, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(address(bytes20(ret)), predicted, "hook deployed at the mined address");
        vm.label(predicted, "hook");
        return SurplusPoolHook(predicted);
    }

    /// @dev An empty address on the requested side of WETH: the top byte decides the order.
    function _v2Address() internal pure returns (address) {
        uint160 seed = uint160(uint256(keccak256("fork.v2"))) >> 8;
        return address(_v2IsCurrency0() ? seed : seed | (uint160(0xFF) << 152));
    }

    /// @dev The launch: the initializer creates the pool at the start price, then liquidity is seeded around it.
    function _launch(PoolKey memory key) internal {
        vm.prank(INITIALIZER);
        int24 tick = MANAGER.initialize(key, _startPrice());
        int24 center = tick / TICK_SPACING * TICK_SPACING;
        (lower, upper) = (center - HALF_RANGE, center + HALF_RANGE);
        actor.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, LIQUIDITY, 0));
    }

    function _launchBoth() internal {
        _launch(official);
        _launch(twin);
    }

    function _startPrice() internal pure returns (uint160) {
        // sqrt(price) * 2^96, price = currency1 per currency0.
        uint256 priceX192 = _v2IsCurrency0() ? (uint256(1) << 192) / V2_PER_WETH : V2_PER_WETH << 192;
        uint256 root = _sqrt(priceX192);
        require(root <= type(uint160).max, "sqrt price overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(root);
    }

    function _sqrtPrice(PoolKey memory key) internal view returns (uint160) {
        bytes32 slot = keccak256(abi.encode(keccak256(abi.encode(key)), POOLS_SLOT));
        return uint160(uint256(MANAGER.extsload(slot)));
    }

    // ----- swap shapes: "buy" = WETH for v2, "sell" = v2 for WETH -----

    function _exactInBuy(uint256 wethIn) internal pure returns (SwapParams memory) {
        return _params(!_v2IsCurrency0(), -_int(wethIn));
    }

    function _exactInSell(uint256 v2In) internal pure returns (SwapParams memory) {
        return _params(_v2IsCurrency0(), -_int(v2In));
    }

    function _exactOutBuy(uint256 v2Out) internal pure returns (SwapParams memory) {
        return _params(!_v2IsCurrency0(), _int(v2Out));
    }

    function _exactOutSell(uint256 wethOut) internal pure returns (SwapParams memory) {
        return _params(_v2IsCurrency0(), _int(wethOut));
    }

    function _params(bool zeroForOne, int256 amountSpecified) internal pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, amountSpecified, zeroForOne ? NO_LIMIT_ZERO_FOR_ONE : NO_LIMIT_ONE_FOR_ZERO);
    }

    /// @dev The swap's output amount: currency1 when selling currency0, currency0 otherwise.
    function _output(int256 delta, SwapParams memory p) internal pure returns (uint256) {
        return _abs(p.zeroForOne ? delta.amount1() : delta.amount0());
    }

    /// @dev Runs `p` on the twin, then on the official pool, and proves the official pool paid out and charged
    ///      exactly what the hookless twin did, in both currencies, that both pools are still at the same price, and
    ///      that the hook holds nothing. Returns the official pool's delta.
    function _swapAndCheck(SwapParams memory p) internal returns (int256 delta) {
        int256 control = actor.swap(twin, p);
        delta = actor.swap(official, p);
        assertEq(int256(delta.amount0()), int256(control.amount0()), "currency0 amount differs from the hookless pool");
        assertEq(int256(delta.amount1()), int256(control.amount1()), "currency1 amount differs from the hookless pool");
        assertEq(uint256(_sqrtPrice(official)), uint256(_sqrtPrice(twin)), "pools stay in lockstep");
        _assertHookHoldsNothing();
    }

    function _assertHookHoldsNothing() internal view {
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0, "the hook holds WETH");
        assertEq(IERC20(address(v2)).balanceOf(address(hook)), 0, "the hook holds v2");
        assertEq(address(hook).balance, 0, "the hook holds ETH");
    }

    /// @dev How the PoolManager surfaces a reverting beforeInitialize: v4-core CustomRevert.bubbleUpAndRevertWith.
    function _gateRevert(bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            IPoolManagerErrors.WrappedError.selector,
            address(hook),
            bytes4(keccak256("beforeInitialize(address,(address,address,uint24,int24,address),uint160)")),
            reason,
            abi.encodeWithSelector(IPoolManagerErrors.HookCallFailed.selector)
        );
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = x / 2 + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }
}
