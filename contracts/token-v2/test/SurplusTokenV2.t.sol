// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SurplusTokenV2} from "../src/SurplusTokenV2.sol";
import {GovernanceDouble} from "./GovernanceDouble.sol";
import {Vm} from "./Base.t.sol";
import {SurplusTokenV2Revision, TokenFixture} from "./TokenFixture.sol";

contract SurplusTokenV2Test is TokenFixture {
    bytes32 internal constant ROLE_GRANTED = keccak256("RoleGranted(bytes32,address,address)");
    bytes internal constant ALREADY_INITIALIZED = bytes("Initializable: contract is already initialized");
    bytes internal constant CAP_EXCEEDED = bytes("ERC20Capped: cap exceeded");

    // ── initialization and deploy parameters ──

    function test_InitializeAppliesDeployParametersWithZeroSupply() public {
        assertEq(token.name(), PLACEHOLDER_NAME, "name is the name parameter");
        assertEq(token.symbol(), PLACEHOLDER_SYMBOL, "symbol is the symbol parameter");
        assertEq(token.cap(), PLACEHOLDER_CAP, "cap is the cap parameter");
        assertEq(token.decimals(), 18, "standard decimals");
        assertEq(token.totalSupply(), 0, "zero initial supply");
        assertEq(token.balanceOf(address(safe)), 0, "nothing preminted to the Safe");
        assertEq(token.balanceOf(deployer), 0, "nothing preminted to the deployer");

        vm.prank(deployer);
        SurplusTokenV2 other = _deployProxy("Other placeholder", "OTHER", 7 ether, address(safe));
        assertEq(other.name(), "Other placeholder", "same implementation, different name");
        assertEq(other.symbol(), "OTHER", "same implementation, different symbol");
        assertEq(other.cap(), 7 ether, "same implementation, different cap");
    }

    function test_InitializeRejectsEmptyMetadata() public {
        vm.expectRevert(SurplusTokenV2.InvalidMetadata.selector);
        _deployProxy("", PLACEHOLDER_SYMBOL, PLACEHOLDER_CAP, address(safe));
        vm.expectRevert(SurplusTokenV2.InvalidMetadata.selector);
        _deployProxy(PLACEHOLDER_NAME, "", PLACEHOLDER_CAP, address(safe));
    }

    function test_InitializeRejectsZeroCap() public {
        vm.expectRevert(bytes("ERC20Capped: cap is 0"));
        _deployProxy(PLACEHOLDER_NAME, PLACEHOLDER_SYMBOL, 0, address(safe));
    }

    function test_InitializeRejectsChainsOtherThanBase() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(SurplusTokenV2.InvalidCanonicalChain.selector, 1));
        _deployProxy(PLACEHOLDER_NAME, PLACEHOLDER_SYMBOL, PLACEHOLDER_CAP, address(safe));
    }

    function test_InitializeRejectsGovernanceWithoutCode() public {
        vm.expectRevert(SurplusTokenV2.InvalidGovernance.selector);
        _deployProxy(PLACEHOLDER_NAME, PLACEHOLDER_SYMBOL, PLACEHOLDER_CAP, address(0));
        vm.expectRevert(SurplusTokenV2.InvalidGovernance.selector);
        _deployProxy(PLACEHOLDER_NAME, PLACEHOLDER_SYMBOL, PLACEHOLDER_CAP, signerQuorum);
    }

    // ── roles: the Safe holds everything, the deployer nothing ──

    function test_SafeHoldsEveryRoleAndAdministersEachOne() public view {
        bytes32[] memory roles = _allRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            assertTrue(token.hasRole(roles[i], address(safe)), "Safe holds the role");
            assertEq(token.getRoleAdmin(roles[i]), DEFAULT_ADMIN_ROLE, "the Safe's admin role administers it");
        }
    }

    function test_InitializationGrantsRolesToTheSafeAndNobodyElse() public {
        vm.recordLogs();
        vm.prank(deployer);
        SurplusTokenV2 fresh = _deployProxy(PLACEHOLDER_NAME, PLACEHOLDER_SYMBOL, PLACEHOLDER_CAP, address(safe));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 grants;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != ROLE_GRANTED) continue;
            assertEq(logs[i].emitter, address(fresh), "grant recorded on the proxy");
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(safe)))), "grantee is the Safe");
            grants++;
        }
        // Every grantee is the Safe, so a count equal to the role matrix also rules out an unlisted role.
        assertEq(grants, _allRoles().length, "exactly one grant per role");
    }

    function test_DeployerHoldsNoRoleOnProxyOrImplementation() public view {
        bytes32[] memory roles = _allRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            assertFalse(token.hasRole(roles[i], deployer), "no role on the proxy");
            assertFalse(implementation.hasRole(roles[i], deployer), "no role on the implementation");
        }
    }

    function test_DeployerCannotMint() public {
        vm.prank(deployer);
        vm.expectRevert(_missingRole(deployer, MINTER_ROLE));
        token.mint(deployer, 1);
        assertEq(token.totalSupply(), 0, "supply unchanged");
    }

    function test_DeployerCannotUpgrade() public {
        SurplusTokenV2Revision successor = new SurplusTokenV2Revision();
        bytes memory reason = _missingRole(deployer, UPGRADER_ROLE);
        vm.prank(deployer);
        vm.expectRevert(reason);
        token.upgradeTo(address(successor));
        vm.prank(deployer);
        vm.expectRevert(reason);
        token.upgradeToAndCall(address(successor), abi.encodeCall(SurplusTokenV2Revision.initializeRevision, (1)));
        assertEq(_implementationOf(address(token)), address(implementation), "implementation unchanged");
    }

    function test_DeployerCannotGrantAnyRole() public {
        bytes32[] memory roles = _allRoles();
        bytes memory reason = _missingRole(deployer, DEFAULT_ADMIN_ROLE);
        for (uint256 i = 0; i < roles.length; i++) {
            vm.prank(deployer);
            vm.expectRevert(reason);
            token.grantRole(roles[i], deployer);
            assertFalse(token.hasRole(roles[i], deployer), "grant did not land");
        }
    }

    function test_SafeCanDelegateAndRevokeMinting() public {
        address delegate = _account(0xDE1E, "delegatedMinter");
        _safeCall(abi.encodeCall(token.grantRole, (MINTER_ROLE, delegate)));
        vm.prank(delegate);
        token.mint(vault, 1 ether);
        assertEq(token.balanceOf(vault), 1 ether, "delegate mints while granted");

        _safeCall(abi.encodeCall(token.revokeRole, (MINTER_ROLE, delegate)));
        vm.prank(delegate);
        vm.expectRevert(_missingRole(delegate, MINTER_ROLE));
        token.mint(vault, 1 ether);
    }

    // ── mint path: the launch batch ──

    function test_LaunchBatchMintsBackingToVaultAndBudgetToHelperInOneSafeTransaction() public {
        _launchMints(PLACEHOLDER_BACKING, PLACEHOLDER_LP_BUDGET);
        assertEq(token.balanceOf(vault), PLACEHOLDER_BACKING, "vault holds the claim backing");
        assertEq(token.balanceOf(launchHelper), PLACEHOLDER_LP_BUDGET, "helper holds the LP budget");
        assertEq(token.totalSupply(), PLACEHOLDER_BACKING + PLACEHOLDER_LP_BUDGET, "supply is the two mints");
        assertEq(token.balanceOf(address(safe)), 0, "the Safe keeps nothing");
    }

    function test_LaunchBatchCanMintExactlyTheCapButNotOneWeiMore() public {
        _launchMints(PLACEHOLDER_CAP - PLACEHOLDER_LP_BUDGET, PLACEHOLDER_LP_BUDGET);
        assertEq(token.totalSupply(), PLACEHOLDER_CAP, "supply equals the cap");

        _safeCallReverts(abi.encodeCall(SurplusTokenV2.mint, (vault, 1)), CAP_EXCEEDED);
        assertEq(token.totalSupply(), PLACEHOLDER_CAP, "cap never exceeded");
    }

    function test_LaunchBatchOneWeiOverTheCapMintsNothing() public {
        GovernanceDouble.Call[] memory calls =
            _launchMintCalls(PLACEHOLDER_CAP - PLACEHOLDER_LP_BUDGET + 1, PLACEHOLDER_LP_BUDGET);
        _safeBatchReverts(calls, CAP_EXCEEDED);
        assertEq(token.balanceOf(vault), 0, "the first mint rolled back with the batch");
        assertEq(token.totalSupply(), 0, "nothing minted");
    }

    function test_NonMinterCannotMint() public {
        _launchMints(PLACEHOLDER_BACKING, PLACEHOLDER_LP_BUDGET);
        address[3] memory callers = [stranger, vault, launchHelper];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(_missingRole(callers[i], MINTER_ROLE));
            token.mint(callers[i], 1);
        }
        assertEq(token.totalSupply(), PLACEHOLDER_BACKING + PLACEHOLDER_LP_BUDGET, "supply unchanged");
    }

    // ── burn: the buyback path ──

    function test_BurnLowersSupplyAndFreesCapHeadroomWhereADeadAddressDoesNot() public {
        _launchMints(PLACEHOLDER_CAP - PLACEHOLDER_LP_BUDGET, PLACEHOLDER_LP_BUDGET);
        vm.prank(launchHelper);
        assertTrue(token.transfer(0x000000000000000000000000000000000000dEaD, 1 ether), "send to the dead address");
        assertEq(token.totalSupply(), PLACEHOLDER_CAP, "a dead-address send leaves supply unchanged");
        _safeCallReverts(abi.encodeCall(SurplusTokenV2.mint, (vault, 1)), CAP_EXCEEDED);

        vm.prank(launchHelper);
        assertTrue(token.transfer(address(safe), 10 ether), "bought-back tokens reach the Safe");
        _safeCall(abi.encodeCall(SurplusTokenV2.burn, (10 ether)));
        assertEq(token.balanceOf(address(safe)), 0, "Safe balance burned");
        assertEq(token.totalSupply(), PLACEHOLDER_CAP - 10 ether, "supply dropped by the burn");

        _safeCallReverts(abi.encodeCall(SurplusTokenV2.mint, (vault, 10 ether + 1)), CAP_EXCEEDED);
        _safeCall(abi.encodeCall(SurplusTokenV2.mint, (vault, 10 ether)));
        assertEq(token.totalSupply(), PLACEHOLDER_CAP, "the burned amount is mintable again, and no more");
    }

    function test_SafeCanGrantBurnToABuybackExecutorAndRevokeIt() public {
        address executor = _account(0xB7B7, "buybackExecutor");
        _launchMints(PLACEHOLDER_BACKING, PLACEHOLDER_LP_BUDGET);
        vm.prank(launchHelper);
        assertTrue(token.transfer(executor, 5 ether), "executor holds bought-back tokens");

        vm.prank(executor);
        vm.expectRevert(_missingRole(executor, BURNER_ROLE));
        token.burn(1 ether);

        _safeCall(abi.encodeCall(token.grantRole, (BURNER_ROLE, executor)));
        vm.prank(executor);
        token.burn(2 ether);
        assertEq(token.balanceOf(executor), 3 ether, "executor burned its own tokens");
        assertEq(token.totalSupply(), PLACEHOLDER_BACKING + PLACEHOLDER_LP_BUDGET - 2 ether, "supply dropped");

        _safeCall(abi.encodeCall(token.revokeRole, (BURNER_ROLE, executor)));
        vm.prank(executor);
        vm.expectRevert(_missingRole(executor, BURNER_ROLE));
        token.burn(1 ether);
    }

    function test_NonBurnerCannotBurnEvenItsOwnBalance() public {
        _launchMints(PLACEHOLDER_BACKING, PLACEHOLDER_LP_BUDGET);
        vm.prank(launchHelper);
        assertTrue(token.transfer(deployer, 1 ether), "deployer holds tokens");
        address[4] memory callers = [stranger, deployer, vault, launchHelper];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(_missingRole(callers[i], BURNER_ROLE));
            token.burn(1);
        }
        assertEq(token.totalSupply(), PLACEHOLDER_BACKING + PLACEHOLDER_LP_BUDGET, "supply unchanged");
    }

    function test_BurnerBurnsOnlyItsOwnBalance() public {
        _launchMints(PLACEHOLDER_BACKING, PLACEHOLDER_LP_BUDGET);
        _safeCallReverts(abi.encodeCall(SurplusTokenV2.burn, (1)), bytes("ERC20: burn amount exceeds balance"));
        assertEq(token.balanceOf(vault), PLACEHOLDER_BACKING, "other holders untouched");
        assertEq(token.totalSupply(), PLACEHOLDER_BACKING + PLACEHOLDER_LP_BUDGET, "supply unchanged");
    }

    // ── ERC-20 behavior through the proxy ──

    function test_TransferApproveAndTransferFrom() public {
        address holder = _account(0xA11CE, "holder");
        address spender = _account(0xB0B, "spender");
        _safeCall(abi.encodeCall(SurplusTokenV2.mint, (holder, 10 ether)));

        vm.prank(holder);
        assertTrue(token.approve(spender, 7 ether), "approve");
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, spender, 3 ether), "transferFrom");
        vm.prank(spender);
        assertTrue(token.transfer(stranger, 1 ether), "transfer");

        assertEq(token.balanceOf(holder), 7 ether, "holder debited");
        assertEq(token.balanceOf(spender), 2 ether, "spender credited, then paid out");
        assertEq(token.balanceOf(stranger), 1 ether, "recipient credited");
        assertEq(token.allowance(holder, spender), 4 ether, "allowance decremented");
        assertEq(token.totalSupply(), 10 ether, "transfers do not mint");

        vm.prank(spender);
        (bool ok, bytes memory reason) =
            address(token).call(abi.encodeCall(token.transferFrom, (holder, spender, 5 ether)));
        assertFalse(ok, "cannot spend beyond the allowance");
        assertEq(
            keccak256(reason),
            keccak256(abi.encodeWithSignature("Error(string)", "ERC20: insufficient allowance")),
            "rejected for the allowance"
        );
    }

    // ── upgrade safety ──

    function test_ImplementationCannotBeInitializedOrUpgradedDirectly() public {
        GovernanceDouble attacker = new GovernanceDouble(stranger);
        vm.prank(stranger);
        vm.expectRevert(ALREADY_INITIALIZED);
        implementation.initialize(PLACEHOLDER_NAME, PLACEHOLDER_SYMBOL, PLACEHOLDER_CAP, address(attacker));

        SurplusTokenV2Revision successor = new SurplusTokenV2Revision();
        vm.prank(stranger);
        vm.expectRevert(bytes("Function must be called through delegatecall"));
        implementation.upgradeTo(address(successor));
    }

    function test_ProxyCannotBeInitializedTwiceEvenByTheSafe() public {
        GovernanceDouble attacker = new GovernanceDouble(stranger);
        vm.prank(stranger);
        vm.expectRevert(ALREADY_INITIALIZED);
        token.initialize("Hijacked", "BAD", 2 * PLACEHOLDER_CAP, address(attacker));

        _safeCallReverts(
            abi.encodeCall(SurplusTokenV2.initialize, ("Hijacked", "BAD", 2 * PLACEHOLDER_CAP, address(safe))),
            ALREADY_INITIALIZED
        );
        assertEq(token.name(), PLACEHOLDER_NAME, "metadata unchanged");
        assertEq(token.cap(), PLACEHOLDER_CAP, "cap unchanged");
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, address(attacker)), "attacker gained nothing");
    }

    function test_StrangerCannotUpgrade() public {
        SurplusTokenV2Revision successor = new SurplusTokenV2Revision();
        bytes memory reason = _missingRole(stranger, UPGRADER_ROLE);
        vm.prank(stranger);
        vm.expectRevert(reason);
        token.upgradeTo(address(successor));
        vm.prank(stranger);
        vm.expectRevert(reason);
        token.upgradeToAndCall(address(successor), abi.encodeCall(SurplusTokenV2Revision.initializeRevision, (7)));
        assertEq(_implementationOf(address(token)), address(implementation), "implementation unchanged");
    }

    function test_SafeCannotUpgradeToANonUUPSImplementation() public {
        // Such an upgrade would leave the proxy with no upgrade function, frozen for good.
        _safeCallReverts(
            abi.encodeCall(token.upgradeTo, (address(safe))), bytes("ERC1967Upgrade: new implementation is not UUPS")
        );
        assertEq(_implementationOf(address(token)), address(implementation), "implementation unchanged");
    }

    function test_SafeUpgradePreservesBalancesAllowancesSupplyMetadataCapAndRoles() public {
        address spender = _account(0x5B, "spender");
        address delegatedMinter = _account(0xDE1E, "delegatedMinter");
        _launchMints(PLACEHOLDER_BACKING, PLACEHOLDER_LP_BUDGET);
        vm.prank(vault);
        assertTrue(token.approve(spender, 60 ether), "approved before the upgrade");
        _safeCall(abi.encodeCall(token.grantRole, (MINTER_ROLE, delegatedMinter)));

        SurplusTokenV2Revision successor = new SurplusTokenV2Revision();
        bytes memory initRevision = abi.encodeCall(SurplusTokenV2Revision.initializeRevision, (42));
        _safeCall(abi.encodeCall(token.upgradeToAndCall, (address(successor), initRevision)));

        assertEq(_implementationOf(address(token)), address(successor), "ERC-1967 slot points at the successor");
        assertEq(SurplusTokenV2Revision(address(token)).marker(), 42, "successor state set in the upgrade");
        _assertPreUpgradeStateIntact(spender, delegatedMinter);

        vm.prank(spender);
        assertTrue(token.transferFrom(vault, spender, 20 ether), "pre-upgrade allowance still spendable");
        assertEq(token.allowance(vault, spender), 40 ether, "and still decrements");
        vm.prank(delegatedMinter);
        token.mint(spender, 1 ether);
        assertEq(token.totalSupply(), PLACEHOLDER_BACKING + PLACEHOLDER_LP_BUDGET + 1 ether, "delegated mint works");

        _safeCallReverts(abi.encodeCall(SurplusTokenV2.mint, (vault, PLACEHOLDER_CAP)), CAP_EXCEEDED);
        _safeCallReverts(initRevision, ALREADY_INITIALIZED);
    }

    function _assertPreUpgradeStateIntact(address spender, address delegatedMinter) internal view {
        assertEq(token.name(), PLACEHOLDER_NAME, "name preserved");
        assertEq(token.symbol(), PLACEHOLDER_SYMBOL, "symbol preserved");
        assertEq(token.decimals(), 18, "decimals preserved");
        assertEq(token.cap(), PLACEHOLDER_CAP, "cap preserved");
        assertEq(token.totalSupply(), PLACEHOLDER_BACKING + PLACEHOLDER_LP_BUDGET, "supply preserved");
        assertEq(token.balanceOf(vault), PLACEHOLDER_BACKING, "vault balance preserved");
        assertEq(token.balanceOf(launchHelper), PLACEHOLDER_LP_BUDGET, "helper balance preserved");
        assertEq(token.allowance(vault, spender), 60 ether, "allowance preserved");
        assertTrue(token.hasRole(MINTER_ROLE, delegatedMinter), "delegated role preserved");
        bytes32[] memory roles = _allRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            assertTrue(token.hasRole(roles[i], address(safe)), "Safe keeps every role");
            assertFalse(token.hasRole(roles[i], deployer), "deployer still holds nothing");
        }
    }
}
