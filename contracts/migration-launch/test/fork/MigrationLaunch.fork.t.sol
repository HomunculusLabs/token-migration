// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MigrationLaunch} from "../../src/MigrationLaunch.sol";
import {MigrationSettler} from "../../src/MigrationSettler.sol";
import {IPositionManager} from "../../src/LaunchInterfaces.sol";
import {ISafe, ISafeProxyFactory, LaunchForkBase} from "./LaunchForkBase.sol";

/// @dev Exposes the settings hash the launch compares before and after, so a test can show what it covers.
contract SettingsProbe is MigrationLaunch {
    constructor(Config memory c, MigrationSettler.Params memory p) MigrationLaunch(c, p) {}

    function safeSettings() external view returns (bytes32) {
        return _safeSettings();
    }
}

/// @dev The launch as one contract, MigrationLaunch, run by the real Safe 1.4.1 through a signed DELEGATECALL on
///      the pinned Base fork. It must launch exactly as the MultiSendCallOnly batch does, write nothing in the Safe,
///      and run only once, only there.
contract MigrationLaunchForkTest is LaunchForkBase {
    /// @dev Safe 1.4.1 storage slot 5 holds `nonce`: the one slot a signed execTransaction itself writes.
    bytes32 internal constant SAFE_NONCE_SLOT = bytes32(uint256(5));
    bytes32 internal constant GS013 = keccak256(abi.encodeWithSignature("Error(string)", "GS013"));

    function test_Launch_V2SortsAboveWeth() public {
        _launchEndToEnd(false);
    }

    function test_Launch_V2SortsBelowWeth() public {
        _launchEndToEnd(true);
    }

    /// @dev From the same pre-state, the contract and the batch it replaces leave the same chain behind: the same sale,
    ///      the same pool at the same price, the same LP NFTs to the Safe, the same balances.
    function test_SameResultAsTheBatch() public {
        _launchSetup(false, true);
        (MigrationSettler.Params memory p, uint256 v2Budget,,) = _signed();
        uint256 snapshot = vm.snapshotState();
        uint256 gasBefore = gasleft();
        (bool ok, bytes memory ret) = _launch(p, v2Budget);
        uint256 batchGas = gasBefore - gasleft();
        require(ok && abi.decode(ret, (bool)), "batch");
        bytes32 batch = _outcome(p);
        require(vm.revertToState(snapshot), "restore");

        MigrationLaunch l = _deployLaunch(p, v2Budget);
        gasBefore = gasleft();
        _runLaunch(l);
        uint256 launchGas = gasBefore - gasleft();
        assertEq(_outcome(p), batch, "the launch contract and the batch diverged");
        emit log_named_uint("batch_exec_gas", batchGas);
        emit log_named_uint("launch_contract_exec_gas", launchGas);
    }

    /// @dev The contract's code runs in the Safe's storage and writes none of it. The only write to the Safe in the
    ///      whole signed transaction is execTransaction's own nonce increment.
    function test_WritesNoSafeStorageButTheNonce() public {
        _launchSetup(false, true);
        MigrationLaunch l = _signedLaunch();
        vm.record();
        _runLaunch(l);
        (, bytes32[] memory writes) = vm.accesses(address(safe));
        assertTrue(writes.length != 0, "recorded no write at all");
        for (uint256 i; i < writes.length; ++i) {
            assertEq(writes[i], SAFE_NONCE_SLOT, "the launch wrote the Safe's storage");
        }
        (, writes) = vm.accesses(address(l));
        assertEq(writes.length, 0, "the launch contract's own storage was written");
    }

    /// @dev Called directly it reverts, and so does a DELEGATECALL from any other account, here a second Safe with
    ///      the same owners, whose signed transaction fails (GS013) and leaves this Safe's launch untouched.
    function test_OnlyThisSafeCanRunIt() public {
        _launchSetup(false, true);
        MigrationLaunch l = _signedLaunch();
        vm.expectRevert(abi.encodeWithSelector(MigrationLaunch.NotRunByTheSafe.selector, address(l)));
        l.launch();

        ISafe other = _anotherSafe();
        _expectInnerRevert(other, l, abi.encodeWithSelector(MigrationLaunch.NotRunByTheSafe.selector, address(other)));
        (bool ok, bytes memory ret) = _safeCallOn(other, address(l), abi.encodeCall(MigrationLaunch.launch, ()), 1);
        assertTrue(!ok && keccak256(ret) == GS013, "another Safe ran the launch");
        assertTrue(!vault.claimsActive() && v2.totalSupply() == 0 && safe.nonce() == 1, "the launch moved");
    }

    /// @dev It runs once: a second signed run reverts at step 2, because claims are already active, and changes nothing.
    function test_RunsOnce() public {
        _launchSetup(false, true);
        MigrationLaunch l = _signedLaunch();
        _runLaunch(l);
        uint256 supply = v2.totalSupply();
        uint256 nonce = safe.nonce();
        (bool ok, bytes memory ret) = _safeCall(address(l), abi.encodeCall(MigrationLaunch.launch, ()), 1);
        assertTrue(!ok && keccak256(ret) == GS013, "a second run succeeded");
        assertTrue(v2.totalSupply() == supply && safe.nonce() == nonce, "the second run changed state");
        _expectInnerRevert(safe, l, abi.encodeWithSignature("ClaimsAlreadyActive()"));
    }

    /// @dev Any failing step reverts all five: here a sale one wei below the signed floor. Nothing is minted, activated
    ///      or released, and the Safe nonce is unused.
    function test_ASaleBelowTheFloorRevertsEverything() public {
        _launchSetup(false, true);
        (MigrationSettler.Params memory p, uint256 v2Budget, uint256 simRaised,) = _signed();
        p.minWethOut = simRaised + 1;
        MigrationLaunch l = _deployLaunch(p, v2Budget);
        uint256 nonce = safe.nonce();
        (bool ok, bytes memory ret) = _safeCall(address(l), abi.encodeCall(MigrationLaunch.launch, ()), 1);
        assertTrue(!ok && keccak256(ret) == GS013, "the launch succeeded below the floor");
        assertTrue(
            !vault.claimsActive() && v2.totalSupply() == 0 && IERC20(V1).balanceOf(address(vault)) == total
                && IERC20(V1).balanceOf(address(settler)) == 0 && safe.nonce() == nonce,
            "a failed launch left state behind"
        );
        _expectInnerRevert(
            safe, l, abi.encodeWithSelector(MigrationSettler.SaleBelowMinimum.selector, simRaised, simRaised + 1)
        );
    }

    /// @dev Numbers built for another claims total, or another ledger, cannot run.
    function test_NumbersForAnotherStateCannotRun() public {
        _launchSetup(false, true);
        (MigrationSettler.Params memory p, uint256 v2Budget,,) = _signed();
        MigrationLaunch l = new MigrationLaunch(_config(total + 1, v2Budget), p);
        _expectInnerRevert(
            safe, l, abi.encodeWithSelector(MigrationLaunch.ClaimsTotalChanged.selector, total, total + 1)
        );

        p.v1In = total - 1;
        l = _deployLaunch(p, v2Budget);
        _expectInnerRevert(safe, l, abi.encodeWithSelector(MigrationLaunch.LedgerChanged.selector, total, total - 1));
    }

    /// @dev Why the kit deploys the contract and checks its code hash before anyone signs: a Safe DELEGATECALL to an
    ///      address with no code succeeds, spends the nonce, and launches nothing.
    function test_NoCodeAtTheTargetIsASilentNoOp() public {
        _launchSetup(false, true);
        address empty = address(uint160(uint256(keccak256("no launch contract here"))));
        require(empty.code.length == 0, "not empty");
        uint256 nonce = safe.nonce();
        (bool ok, bytes memory ret) = _safeCall(empty, abi.encodeCall(MigrationLaunch.launch, ()), 1);
        assertTrue(ok && abi.decode(ret, (bool)), "the Safe transaction itself succeeded");
        assertTrue(safe.nonce() == nonce + 1 && !vault.claimsActive() && v2.totalSupply() == 0, "and launched nothing");
    }

    /// @dev The before/after settings hash moves with each setting that decides who controls the Safe: threshold,
    ///      owners, modules, fallback handler. (The guard and singleton are raw slots read the same way; setting them
    ///      needs a guard contract or an upgrade, so they are not exercised here.)
    function test_TheSettingsCheckSeesEachSetting() public {
        _launchSetup(false, true);
        (MigrationSettler.Params memory p, uint256 v2Budget,,) = _signed();
        SettingsProbe probe = new SettingsProbe(_config(total, v2Budget), p);
        bytes32 start = probe.safeSettings();
        bytes[4] memory changes = [
            abi.encodeWithSignature("changeThreshold(uint256)", 1),
            abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", address(0xA11), 2),
            abi.encodeWithSignature("enableModule(address)", address(0xA22)),
            abi.encodeWithSignature("setFallbackHandler(address)", address(0xA33))
        ];
        for (uint256 i; i < changes.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            _safeExec(address(safe), changes[i]);
            assertTrue(probe.safeSettings() != start, "a Safe setting the launch does not see");
            require(vm.revertToState(snapshot), "restore");
        }
        assertEq(probe.safeSettings(), start, "the settings hash is stable");
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _launchEndToEnd(bool v2BelowWeth) internal {
        _launchSetup(v2BelowWeth, true);
        (MigrationSettler.Params memory p, uint256 v2Budget, uint256 simRaised) = _signedWithLaunch();
        MigrationLaunch l = _deployLaunch(p, v2Budget);
        assertEq(keccak256(abi.encode(l.settleParams())), keccak256(abi.encode(p)), "stored params");
        uint256 nonceBefore = safe.nonce();
        _runLaunch(l);
        assertEq(safe.nonce(), nonceBefore + 1, "one Safe transaction");
        _assertLaunched(p, v2Budget, simRaised);
    }

    /// @dev Simulate-then-sign with the launch contract itself, as the kit does: an unconstrained contract (no floor,
    ///      the whole remaining cap as budget) runs and is discarded; the signed limits follow §4.4.
    function _signedWithLaunch()
        internal
        returns (MigrationSettler.Params memory p, uint256 v2Budget, uint256 simRaised)
    {
        p = _params();
        uint256 snapshot = vm.snapshotState();
        _runLaunch(_deployLaunch(p, V2_CAP - total));
        simRaised = settler.wethRaised();
        uint256 simV2 = settler.v2Seeded();
        require(vm.revertToState(snapshot), "revert to the pre-simulation state");
        p.minWethOut = (simRaised * 995) / 1000;
        v2Budget = simV2 + 10;
    }

    function _signedLaunch() internal returns (MigrationLaunch) {
        (MigrationSettler.Params memory p, uint256 v2Budget,,) = _signed();
        return _deployLaunch(p, v2Budget);
    }

    function _config(uint256 v2ForClaims, uint256 v2ForPool) internal view returns (MigrationLaunch.Config memory) {
        return MigrationLaunch.Config({
            safe: address(safe),
            vault: address(vault),
            v2: address(v2),
            settler: address(settler),
            v2ForClaims: v2ForClaims,
            v2ForPool: v2ForPool
        });
    }

    function _deployLaunch(MigrationSettler.Params memory p, uint256 v2Budget) internal returns (MigrationLaunch) {
        return new MigrationLaunch(_config(total, v2Budget), p);
    }

    /// @dev ONE signed Safe transaction: a DELEGATECALL (operation 1) to the launch contract's `launch()`.
    function _runLaunch(MigrationLaunch l) internal {
        (bool ok, bytes memory ret) = _safeCall(address(l), abi.encodeCall(MigrationLaunch.launch, ()), 1);
        require(ok && abi.decode(ret, (bool)), "the launch contract did not launch");
    }

    /// @dev The exact revert a Safe transaction reports only as GS013. Safe 1.4.1's own `simulateAndRevert` (anyone may
    ///      call it) runs `launch()` by DELEGATECALL in the Safe's context, then reverts with (success, length,
    ///      return data), so nothing it did persists.
    function _expectInnerRevert(ISafe target, MigrationLaunch l, bytes memory expected) internal {
        bytes memory payload = abi.encodeCall(MigrationLaunch.launch, ());
        (bool ok, bytes memory ret) =
            address(target).call(abi.encodeWithSignature("simulateAndRevert(address,bytes)", address(l), payload));
        require(!ok && ret.length >= 64, "simulateAndRevert did not revert with its result");
        bytes memory inner = new bytes(ret.length - 64);
        for (uint256 i; i < inner.length; ++i) {
            inner[i] = ret[64 + i];
        }
        uint256 success;
        for (uint256 i; i < 32; ++i) {
            success = (success << 8) | uint8(ret[i]);
        }
        assertTrue(success == 0, "the launch succeeded in the Safe's context");
        assertEq(keccak256(inner), keccak256(expected), "the inner revert");
    }

    /// @dev A second Safe owned by the same three keys.
    function _anotherSafe() internal returns (ISafe) {
        address[] memory owners = new address[](3);
        owners[0] = vm.addr(KEY_A);
        owners[1] = vm.addr(KEY_B);
        owners[2] = vm.addr(KEY_C);
        return ISafe(
            ISafeProxyFactory(SAFE_FACTORY)
                .createProxyWithNonce(
                    SAFE_SINGLETON,
                    abi.encodeCall(
                        ISafe.setup, (owners, 2, address(0), "", address(0), address(0), 0, payable(address(0)))
                    ),
                    0x07e4
                )
        );
    }

    /// @dev Everything the launch leaves behind, hashed.
    function _outcome(MigrationSettler.Params memory p) internal view returns (bytes32) {
        (bool backed, uint256 held, uint256 claimable, uint256 custody, bool active,) = vault.verifySettlement();
        (uint160 sqrtPriceX96, uint24 lpFee, uint128 liq) = _poolState(keccak256(abi.encode(p.newKey)));
        uint256 first = settler.firstPositionId();
        address[] memory owners = new address[](settler.positionCount());
        for (uint256 i; i < owners.length; ++i) {
            owners[i] = IPositionManager(POSITION_MANAGER).ownerOf(first + i);
        }
        return keccak256(
            abi.encode(
                [settler.wethRaised(), settler.wethSeeded(), settler.v2Seeded(), first, settler.positionCount()],
                settler.wethLiquidity(),
                [sqrtPriceX96, uint256(lpFee), uint256(liq), uint256(_sqrtPrice(OLD_POOL_ID))],
                owners,
                [backed, active],
                [held, claimable, custody, v2.totalSupply()],
                [
                    IERC20(WETH).balanceOf(address(safe)),
                    v2.balanceOf(address(safe)),
                    IERC20(V1).balanceOf(address(safe))
                ]
            )
        );
    }
}
