// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationLaunch} from "../src/MigrationLaunch.sol";
import {MigrationSettler} from "../src/MigrationSettler.sol";
import {PoolKey} from "../src/LaunchInterfaces.sol";
import {Test} from "./Base.t.sol";
import {StubSettler, StubVault} from "./utils/LaunchStubs.sol";

/**
 * @dev The stateful invariant suite: `launch()`'s state machine under a random interleaving of hostile calls.
 *
 * The Safe address carries a REAL delegate-proxy (vm.etch of FuzzSafe: `launch()` delegatecalls into
 * MigrationLaunch, the settings views are answered by the proxy itself), and the vault, settler and tokens are
 * minimal functional doubles of the exact surface the launch touches, so the five steps of `launch()` genuinely
 * execute. The fuzzer then interleaves: launch attempts from the Safe, direct launch calls, launch attempts
 * through impostor proxies etched at random addresses, arbitrary calldata into the params store and into the
 * Safe, and post-launch claimable tampering. The invariants assert what the contract promises:
 *
 *  - launch runs AT MOST ONCE, and exactly the amounts it was built with (funds conservation);
 *  - before the first successful launch nothing moved;
 *  - the contract's code, the store's code, the Safe's code and the stored settle params never change;
 *  - the contract never holds a balance;
 *  - every launch attempt from anywhere but the Safe reverts NotRunByTheSafe.
 */
contract LaunchInvariantTest is Test {
    Handler internal handler;

    function setUp() public {
        vm.deal(msg.sender, 1 ether); // the invariant fuzzer's raw calls pay the fork's base fee
        handler = new Handler();
        handler.initialize();
    }

    /// @dev Non-vacuity proof for local runs: the handler CAN complete a launch off-fork (the
    ///      WethStub double makes the post-settlement WETH reads answer). If this ever fails, the
    ///      local invariant campaign is passing without ever launching again.
    function test_HandlerLaunchCompletesWithoutFork() public {
        handler.doLaunch();
        assertEq(handler.launchesDone(), 1, "the local campaign must be able to launch");
    }

    function targetContracts() public view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(handler);
    }

    function invariant_settleParamsIntact() public view {
        assertTrue(keccak256(abi.encode(handler.launch().settleParams())) == handler.theParamsHash(), "params");
        assertTrue(keccak256(handler.launch().SETTLE_PARAMS().code) == handler.theStoreCodeHash(), "store code");
    }

    function invariant_codesImmutable() public view {
        assertTrue(handler.theLaunchCodeHash() == keccak256(address(handler.launch()).code), "launch code");
        assertTrue(handler.theSafeCodeHash() == keccak256(handler.safe().code), "safe code");
        assertTrue(handler.theVaultCodeHash() == keccak256(address(handler.theVault()).code), "vault code");
        assertTrue(handler.theSettlerCodeHash() == keccak256(address(handler.theSettler()).code), "settler code");
    }

    function invariant_launchAtMostOnce() public view {
        assertTrue(handler.launchesDone() <= 1, "launched more than once");
        assertTrue(
            handler.theV2().totalSupply()
                == handler.supplyBefore() + (handler.launchesDone() == 1 ? handler.claims() + handler.pool() : 0),
            "v2 conservation"
        );
        if (handler.launchesDone() == 1) {
            assertTrue(handler.theVault().active(), "claims active");
            assertTrue(handler.theVault().released() == handler.sale(), "v1 released exactly once");
            assertTrue(handler.theSettler().done(), "settler settled");
        }
    }

    function invariant_nothingMovedBeforeLaunch() public view {
        if (handler.launchesDone() == 0) {
            assertTrue(!handler.theVault().active(), "vault untouched");
            assertTrue(!handler.theSettler().done(), "settler untouched");
            assertTrue(handler.theV2().totalSupply() == handler.supplyBefore(), "no v2 minted");
            assertTrue(handler.theVault().released() == 0, "no v1 released");
        }
    }

    function invariant_launchNeverHoldsFunds() public view {
        assertTrue(handler.theV1().balanceOf(address(handler.launch())) == 0, "v1");
        assertTrue(handler.theV2().balanceOf(address(handler.launch())) == 0, "v2");
        assertTrue(address(handler.launch()).balance == 0, "eth");
    }
}

/// @dev Drives the system. Every public function is a fuzzer action; the ones that must revert assert it
///      themselves, so `fail_on_revert = false` never swallows a broken guard.
contract Handler is Test {
    address internal constant SAFE = address(0x5AFE);
    address internal constant V1_ADDR = address(0x1111);
    address internal constant V2_ADDR = address(0x2222);
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant SINK = address(0x000000000000000000000000000000000000dEaD);

    MiniToken internal v1;
    MintableToken internal v2;
    DoubleVault internal vault;
    DoubleSettler internal settlerStub;
    MigrationLaunch internal launchContract;
    bytes32 internal paramsHash;
    bytes32 internal storeCodeHash;
    bytes32 internal launchCodeHash;
    bytes32 internal safeCodeHash;
    bytes32 internal vaultCodeHash;
    bytes32 internal settlerCodeHash;
    uint256 internal v2SupplyBefore;
    uint256 internal successfulLaunches;

    function initialize() public {
        require(address(v1) == address(0), "once");
        v1 = new MiniToken();
        v2 = new MintableToken();
        // Off-fork, the canonical WETH address has no code and the launch's post-settlement check
        // (IERC20(WETH).balanceOf(SETTLER)) would revert on the empty returndata, so no handler
        // campaign could ever complete a launch locally. Etch a minimal double ONLY when the
        // address is codeless — fork runs keep the real WETH untouched.
        if (address(0x4200000000000000000000000000000000000006).code.length == 0) {
            vm.etch(address(0x4200000000000000000000000000000000000006), type(WethStub).runtimeCode);
        }
        vault = new DoubleVault(SAFE, v1, v2);
        settlerStub = new DoubleSettler(SAFE, address(v1), address(v2), WETH);

        MigrationSettler.Params memory p = _params();
        v1.mint(address(vault), p.v1In); // the migrated v1 sits in the vault
        vault.setTotals(2_200 ether, p.v1In);
        v2.setMinter(SAFE);
        launchContract = new MigrationLaunch(
            MigrationLaunch.Config({
                safe: SAFE,
                vault: address(vault),
                v2: address(v2), // the REAL token here, so the settler/vault wiring checks see one system
                settler: address(settlerStub),
                v2ForClaims: 2_200 ether,
                v2ForPool: 98 ether + 10
            }),
            p
        );
        paramsHash = keccak256(abi.encode(p));
        storeCodeHash = keccak256(launchContract.SETTLE_PARAMS().code);
        launchCodeHash = keccak256(address(launchContract).code);

        // The Safe: a delegate-proxy whose `launch()` runs the real contract at the Safe's address, and whose
        // settings views answer directly, like the real Safe's runtime does.
        vm.etch(SAFE, address(new FuzzSafe(address(launchContract), SAFE, SAFE)).code);
        safeCodeHash = keccak256(SAFE.code);
        vaultCodeHash = keccak256(address(vault).code);
        settlerCodeHash = keccak256(address(settlerStub).code);
        v2SupplyBefore = v2.totalSupply();
    }

    // ------------------------------------------------------------- fuzzer actions

    function doLaunch() public {
        (bool ok,) = SAFE.call(abi.encodeWithSelector(MigrationLaunch.launch.selector));
        if (successfulLaunches == 0) {
            assertTrue(ok, "first launch must succeed");
            successfulLaunches = 1;
        } else {
            assertTrue(!ok, "second launch must revert");
        }
    }

    function doLaunchDirect() public {
        vm.expectRevert(abi.encodeWithSelector(MigrationLaunch.NotRunByTheSafe.selector, address(launchContract)));
        launchContract.launch();
    }

    function doLaunchFromImpostor(uint152 seed) public {
        // An impostor proxy in a dedicated address band that can never collide with the known contracts.
        address impostor = address((uint160(0xbe) << 152) | uint160(seed));
        bytes memory code = address(new NakedProxy(address(launchContract))).code;
        vm.etch(impostor, code);
        (bool ok, bytes memory ret) = impostor.call(abi.encodeWithSelector(MigrationLaunch.launch.selector));
        assertTrue(!ok, "impostor must revert");
        assertTrue(_revertIs(ret, MigrationLaunch.NotRunByTheSafe.selector), "wrong impostor revert");
    }

    function _revertIs(bytes memory ret, bytes4 sel) internal pure returns (bool) {
        if (ret.length < 4) return false;
        for (uint256 i; i < 4; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (ret[i] != bytes1(sel >> (8 * (3 - i)))) return false;
        }
        return true;
    }

    function doPokeStore(bytes4 sel, bytes calldata tail) public {
        (bool ok, bytes memory ret) = launchContract.SETTLE_PARAMS().call(abi.encodePacked(sel, tail));
        assertTrue(ok && ret.length == 0, "store must stay inert");
    }

    function doSendGarbageToSafe(bytes calldata data) public {
        // If the random calldata happens to BE launch(), that is doLaunch's job, not garbage.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (data.length >= 4 && bytes4(data) == MigrationLaunch.launch.selector) {
            revert("skip launch selector");
        }
        // Anything else reaches MigrationLaunch through the proxy and reverts (no fallback); the settings
        // selectors answer and return. Either way the invariants watch the state.
        // forge-lint: disable-next-line(unchecked-call)
        (bool accepted,) = SAFE.call(data);
        accepted; // deliberately unchecked: the invariants watch the state
    }

    /// @dev Pre-launch only: move the committed total, prove the launch refuses to run (ClaimsTotalChanged),
    ///      then restore. Post-launch the vault is frozen, so the action is a no-op.
    function doTamperClaimable(uint88 delta) public {
        if (successfulLaunches != 0) return;
        vault.setTotals(2_200 ether + 1 + delta, vault.deposited());
        (bool ok,) = SAFE.call(abi.encodeWithSelector(MigrationLaunch.launch.selector));
        assertTrue(!ok, "tampered launch must revert");
        vault.setTotals(2_200 ether, vault.deposited());
    }

    // ------------------------------------------------------------------- getters

    function launch() external view returns (MigrationLaunch) {
        return launchContract;
    }

    function safe() external pure returns (address) {
        return SAFE;
    }

    function theVault() external view returns (DoubleVault) {
        return vault;
    }

    function theSettler() external view returns (DoubleSettler) {
        return settlerStub;
    }

    function theV1() external view returns (MiniToken) {
        return v1;
    }

    function theV2() external view returns (MintableToken) {
        return v2;
    }

    function claims() external pure returns (uint256) {
        return 2_200 ether;
    }

    function pool() external pure returns (uint256) {
        return 98 ether + 10;
    }

    function sale() external pure returns (uint256) {
        return 2_200 ether;
    }

    function launchesDone() external view returns (uint256) {
        return successfulLaunches;
    }

    function supplyBefore() external view returns (uint256) {
        return v2SupplyBefore;
    }

    function theParamsHash() external view returns (bytes32) {
        return paramsHash;
    }

    function theStoreCodeHash() external view returns (bytes32) {
        return storeCodeHash;
    }

    function theLaunchCodeHash() external view returns (bytes32) {
        return launchCodeHash;
    }

    function theSafeCodeHash() external view returns (bytes32) {
        return safeCodeHash;
    }

    function theVaultCodeHash() external view returns (bytes32) {
        return vaultCodeHash;
    }

    function theSettlerCodeHash() external view returns (bytes32) {
        return settlerCodeHash;
    }

    function _params() internal pure returns (MigrationSettler.Params memory p) {
        p.oldKey = PoolKey(WETH, V1_ADDR, 0x800000, 200, address(0xD0));
        p.v1In = 2_200 ether;
        p.tailIn = 220 ether;
        p.tailLimit = 1461446703485210103287273052203988822378723970341;
        p.newKey = PoolKey(WETH, V2_ADDR, 3000, 60, address(0x2044));
        p.openTick = 57_480;
        p.v2Ranges = new MigrationSettler.V2Range[](3);
        p.v2Ranges[0] = MigrationSettler.V2Range(-887_220, 40_020, 1e18);
        p.v2Ranges[1] = MigrationSettler.V2Range(40_020, 57_420, 2e21);
        p.v2Ranges[2] = MigrationSettler.V2Range(57_420, 57_480, 3e23);
        p.minWethOut = 269_663_702_174_597_524;
    }
}

/// @dev The Safe's stand-in: `launch()` (and anything unknown) delegatecalls the launch contract — so its code
///      runs AT the Safe's address, like the real Safe's DELEGATECALL — while the settings views answer here.
contract FuzzSafe {
    address internal immutable TARGET;
    address internal immutable EXPECTED_SAFE;

    constructor(address target, address expectedSafe, address) {
        TARGET = target;
        EXPECTED_SAFE = expectedSafe;
    }

    function getOwners() external view returns (address[] memory) {
        address[] memory o = new address[](1);
        o[0] = EXPECTED_SAFE;
        return o;
    }

    function getThreshold() external pure returns (uint256) {
        return 1;
    }

    function getModulesPaginated(address, uint256) external pure returns (address[] memory array, address next) {
        array = new address[](0);
        next = address(0x1);
    }

    function getStorageAt(uint256, uint256) external pure returns (bytes memory) {
        return new bytes(32);
    }

    fallback() external {
        address t = TARGET;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let r := delegatecall(gas(), t, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch r
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

/// @dev A proxy that forwards everything and answers nothing itself: what an impostor's code looks like.
contract NakedProxy {
    address internal immutable TARGET;

    constructor(address target) {
        TARGET = target;
    }

    fallback() external {
        address t = TARGET;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let r := delegatecall(gas(), t, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch r
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

/// @dev The vault slice the launch drives, with the real one-shot rules: activateClaims once, by the Safe,
///      only with full backing; withdrawV1ForSettlement once, by the Safe, only after activation.
contract DoubleVault {
    address internal immutable OWNER;
    MiniToken internal immutable TOKEN_V1;
    MintableToken internal immutable TOKEN_V2;
    uint256 internal claimable;
    uint256 internal totalDeposited;
    uint256 internal withdrawn;
    bool internal isActive;
    bool internal isReleased;

    constructor(address owner_, MiniToken v1_, MintableToken v2_) {
        OWNER = owner_;
        TOKEN_V1 = v1_;
        TOKEN_V2 = v2_;
    }

    function setTotals(uint256 claimable_, uint256 deposited_) external {
        require(!isActive, "frozen once active");
        claimable = claimable_;
        totalDeposited = deposited_;
    }

    function owner() external view returns (address) {
        return OWNER;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function V1() external view returns (address) {
        return address(TOKEN_V1);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function V2() external view returns (address) {
        return address(TOKEN_V2);
    }

    function totalClaimable() external view returns (uint256) {
        return claimable;
    }

    function totalDepositedV1() external view returns (uint256) {
        return totalDeposited;
    }

    function totalLedgerWithdrawnV1() external view returns (uint256) {
        return withdrawn;
    }

    function activateClaims() external {
        require(msg.sender == OWNER, "safe only");
        require(!isActive, "already active");
        require(TOKEN_V2.balanceOf(address(this)) >= claimable, "backing");
        isActive = true;
    }

    function withdrawV1ForSettlement(address to, uint256 amount) external {
        require(msg.sender == OWNER, "safe only");
        require(isActive, "not active");
        require(!isReleased, "already released");
        require(amount == totalDeposited - withdrawn, "whole ledger only");
        isReleased = true;
        withdrawn += amount;
        require(TOKEN_V1.transfer(to, amount), "v1 transfer");
    }

    function verifySettlement()
        external
        view
        returns (
            bool backed,
            uint256 v2Balance,
            uint256 claimableOut,
            uint256 v1InCustody,
            bool active_,
            uint256 claimed
        )
    {
        v2Balance = TOKEN_V2.balanceOf(address(this));
        claimableOut = claimable;
        v1InCustody = TOKEN_V1.balanceOf(address(this));
        backed = isActive && v2Balance >= claimable;
        active_ = isActive;
        claimed = 0;
    }

    function active() external view returns (bool) {
        return isActive;
    }

    function released() external view returns (uint256) {
        return withdrawn;
    }

    function deposited() external view returns (uint256) {
        return totalDeposited;
    }
}

/// @dev The settler surface the launch drives: settle once, as the Safe, leaving nothing behind.
contract DoubleSettler {
    address public immutable SAFE;
    address public immutable V1;
    address public immutable V2;
    address public immutable WETH;
    bool internal isDone;
    uint256 internal raised;
    uint256 internal positions;

    constructor(address safe, address v1, address v2, address weth) {
        SAFE = safe;
        V1 = v1;
        V2 = v2;
        WETH = weth;
    }

    function settle(MigrationSettler.Params calldata p) external {
        require(msg.sender == SAFE, "safe only");
        require(!isDone, "already settled");
        isDone = true;
        // "Sell": the v1 goes to the sink. The WETH it "raises" is exactly the signed floor.
        require(MiniToken(V1).transfer(address(0x000000000000000000000000000000000000dEaD), p.v1In), "v1 sink");
        raised = p.minWethOut;
        positions = p.v2Ranges.length + 1;
        // Anything still held (the minted pool v2) returns to the Safe, as the real seed's leftover does.
        require(MintableToken(V2).transfer(SAFE, MintableToken(V2).balanceOf(address(this))), "v2 return");
    }

    function wethRaised() external view returns (uint256) {
        return raised;
    }

    function positionCount() external view returns (uint256) {
        return positions;
    }

    function done() external view returns (bool) {
        return isDone;
    }
}

contract WethStub {
    /// @dev Minimal stand-in for WETH off-fork: balances stay zero, transfers succeed. The doubles
    ///      record their "raised" WETH internally, so the launch's reads only need to decode.
    mapping(address => uint256) public balanceOf;

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract MiniToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev v2: minting is the Safe's right, as on the real token.
contract MintableToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    address public minter;

    function setMinter(address m) external {
        require(minter == address(0));
        minter = m;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
