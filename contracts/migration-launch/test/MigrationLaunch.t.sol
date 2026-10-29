// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationLaunch} from "../src/MigrationLaunch.sol";
import {MigrationSettler} from "../src/MigrationSettler.sol";
import {PoolKey} from "../src/LaunchInterfaces.sol";
import {Test} from "./Base.t.sol";
import {StubSettler, StubVault} from "./utils/LaunchStubs.sol";

/// @dev MigrationLaunch without a chain: what it stores, what it refuses to be built from, and where it refuses to
///      run. The launch itself runs through the real Safe in test/fork/MigrationLaunch.fork.t.sol.
contract MigrationLaunchTest is Test {
    address internal constant SAFE = address(0x5AFE);
    address internal constant V1 = address(0x1111);
    address internal constant V2 = address(0x2222);
    address internal constant WETH = address(0x4200000000000000000000000000000000000006);

    StubSettler internal settler = new StubSettler(SAFE, V1, V2, WETH);
    StubVault internal vault = new StubVault(SAFE, V1, V2);

    function test_StoresEveryNumberAndTheWholeSettleInput() public {
        MigrationSettler.Params memory p = _params();
        MigrationLaunch l = new MigrationLaunch(_config(), p);

        assertEq(l.SAFE(), SAFE, "SAFE");
        assertEq(l.VAULT(), address(vault), "VAULT");
        assertEq(l.SETTLER(), address(settler), "SETTLER");
        assertEq(l.V1(), V1, "V1 from the settler");
        assertEq(l.V2(), V2, "V2");
        assertEq(l.WETH(), WETH, "WETH from the settler");
        assertEq(l.V2_FOR_CLAIMS(), 2_200 ether, "V2_FOR_CLAIMS");
        assertEq(l.V2_FOR_POOL(), 98 ether + 10, "V2_FOR_POOL");
        assertEq(l.V1_FOR_SALE(), p.v1In, "V1_FOR_SALE");
        assertEq(l.V1_SOLD_ON_V3_TAIL(), p.tailIn, "V1_SOLD_ON_V3_TAIL");
        assertEq(l.MIN_WETH_OUT(), p.minWethOut, "MIN_WETH_OUT");
        assertTrue(l.OPEN_TICK() == p.openTick, "OPEN_TICK");
        assertEq(l.NEW_POOL_ID(), keccak256(abi.encode(p.newKey)), "NEW_POOL_ID");
        assertEq(l.V2_RANGES(), 3, "V2_RANGES");

        bytes memory encoded = abi.encode(p);
        assertEq(l.SETTLE_PARAMS_HASH(), keccak256(encoded), "SETTLE_PARAMS_HASH");
        assertEq(keccak256(l.SETTLE_PARAMS().code), keccak256(abi.encodePacked(hex"00", encoded)), "stored bytes");
        assertEq(keccak256(abi.encode(l.settleParams())), keccak256(encoded), "settleParams() round trip");
    }

    /// @dev A call into the params store hits its leading STOP: it succeeds and returns nothing.
    function test_TheParamsStoreCannotBeCalledInto() public {
        MigrationLaunch l = new MigrationLaunch(_config(), _params());
        (bool ok, bytes memory ret) = l.SETTLE_PARAMS().call(abi.encodeWithSignature("anything()"));
        assertTrue(ok && ret.length == 0, "the store executed something");
    }

    function test_RefusesASettlerOfAnotherSafeOrToken() public {
        MigrationLaunch.Config memory c = _config();
        c.settler = address(new StubSettler(address(0xBAD), V1, V2, WETH));
        _expectInvalid(c, _params(), "settler");
        c.settler = address(new StubSettler(SAFE, V1, address(0xBAD), WETH));
        _expectInvalid(c, _params(), "settler");
        c = _config();
        c.safe = address(0);
        _expectInvalid(c, _params(), "settler");
    }

    function test_RefusesAVaultOfAnotherSafeOrToken() public {
        MigrationLaunch.Config memory c = _config();
        c.vault = address(new StubVault(address(0xBAD), V1, V2));
        _expectInvalid(c, _params(), "vault");
        c.vault = address(new StubVault(SAFE, address(0xBAD), V2));
        _expectInvalid(c, _params(), "vault");
        c.vault = address(new StubVault(SAFE, V1, address(0xBAD)));
        _expectInvalid(c, _params(), "vault");
    }

    function test_RefusesEmptyAmounts() public {
        MigrationLaunch.Config memory c = _config();
        c.v2ForClaims = 0;
        _expectInvalid(c, _params(), "amounts");
        c = _config();
        c.v2ForPool = 0;
        _expectInvalid(c, _params(), "amounts");
        MigrationSettler.Params memory p = _params();
        p.v1In = 0;
        _expectInvalid(_config(), p, "params");
        p = _params();
        p.v2Ranges = new MigrationSettler.V2Range[](0);
        _expectInvalid(_config(), p, "params");
    }

    /// @dev Called directly, `address(this)` is the contract itself, never the Safe.
    function test_RunsOnlyAtTheSafe() public {
        MigrationLaunch l = new MigrationLaunch(_config(), _params());
        vm.expectRevert(abi.encodeWithSelector(MigrationLaunch.NotRunByTheSafe.selector, address(l)));
        l.launch();
    }

    function _expectInvalid(MigrationLaunch.Config memory c, MigrationSettler.Params memory p, string memory reason)
        internal
    {
        vm.expectRevert(abi.encodeWithSelector(MigrationLaunch.InvalidLaunch.selector, reason));
        new MigrationLaunch(c, p);
    }

    function _config() internal view returns (MigrationLaunch.Config memory) {
        return MigrationLaunch.Config({
            safe: SAFE,
            vault: address(vault),
            v2: V2,
            settler: address(settler),
            v2ForClaims: 2_200 ether,
            v2ForPool: 98 ether + 10
        });
    }

    /// @dev Shaped like a real launch (v2 above WETH: the v2 side sits below the opening tick, the last range at it);
    ///      the values only have to survive storage.
    function _params() internal pure returns (MigrationSettler.Params memory p) {
        p.oldKey = PoolKey(WETH, V1, 0x800000, 200, address(0xD0)); // Doppler: dynamic-fee flag, its hook
        p.v1In = 2_200 ether;
        p.tailIn = 220 ether;
        p.tailLimit = 1461446703485210103287273052203988822378723970341;
        p.newKey = PoolKey(WETH, V2, 3000, 60, address(0x2044));
        p.openTick = 57_480;
        p.v2Ranges = new MigrationSettler.V2Range[](3);
        p.v2Ranges[0] = MigrationSettler.V2Range(-887_220, 40_020, 1e18);
        p.v2Ranges[1] = MigrationSettler.V2Range(40_020, 57_420, 2e21);
        p.v2Ranges[2] = MigrationSettler.V2Range(57_420, 57_480, 3e23);
        p.minWethOut = 269_663_702_174_597_524;
    }
}
