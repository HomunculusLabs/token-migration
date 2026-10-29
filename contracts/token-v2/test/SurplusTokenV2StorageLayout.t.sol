// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SurplusTokenV2Revision, TokenFixture} from "./TokenFixture.sol";

/// @notice Reads the proxy's raw storage at the slots recorded in storage-layout.json. An upgrade must
///         leave every one of these where it is, so any layout change that moves one fails here.
contract SurplusTokenV2StorageLayoutTest is TokenFixture {
    uint256 internal constant INITIALIZABLE_SLOT = 0; // _initialized (uint8) and _initializing (bool)
    uint256 internal constant BALANCES_SLOT = 51;
    uint256 internal constant ALLOWANCES_SLOT = 52;
    uint256 internal constant TOTAL_SUPPLY_SLOT = 53;
    uint256 internal constant NAME_SLOT = 54;
    uint256 internal constant SYMBOL_SLOT = 55;
    uint256 internal constant CAP_SLOT = 101;
    uint256 internal constant ROLES_SLOT = 202;
    // The slot after SurplusTokenV2's own __gap (352-401), where state appended by a derived successor starts.
    uint256 internal constant FIRST_SUCCESSOR_SLOT = 402;

    address internal spender;

    function setUp() public override {
        super.setUp();
        spender = _account(0x5B, "spender");
        _launchMints(PLACEHOLDER_BACKING, PLACEHOLDER_LP_BUDGET);
        vm.prank(vault);
        assertTrue(token.approve(spender, 60 ether), "allowance to pin");
    }

    function test_CriticalStateSitsAtThePinnedSlots() public view {
        _assertPinnedSlots(1, address(implementation));
        assertEq(
            vm.load(address(implementation), bytes32(INITIALIZABLE_SLOT)),
            bytes32(uint256(type(uint8).max)),
            "implementation initializers are disabled"
        );
    }

    function test_SafeUpgradeKeepsThePinnedSlotsAndAppendsAfterThem() public {
        SurplusTokenV2Revision successor = new SurplusTokenV2Revision();
        bytes memory initRevision = abi.encodeCall(SurplusTokenV2Revision.initializeRevision, (42));
        _safeCall(abi.encodeCall(token.upgradeToAndCall, (address(successor), initRevision)));

        _assertPinnedSlots(2, address(successor));
        assertEq(
            vm.load(address(token), bytes32(FIRST_SUCCESSOR_SLOT)), bytes32(uint256(42)), "appended state follows V2"
        );
    }

    function _assertPinnedSlots(uint256 initializedVersion, address expectedImplementation) internal view {
        address proxy = address(token);
        assertEq(vm.load(proxy, bytes32(INITIALIZABLE_SLOT)), bytes32(initializedVersion), "initializer version");
        assertEq(_word(proxy, _mappingSlot(vault, BALANCES_SLOT)), PLACEHOLDER_BACKING, "vault balance");
        assertEq(_word(proxy, _mappingSlot(launchHelper, BALANCES_SLOT)), PLACEHOLDER_LP_BUDGET, "helper balance");
        bytes32 vaultAllowances = _mappingSlot(vault, ALLOWANCES_SLOT);
        assertEq(_word(proxy, _mappingSlot(spender, uint256(vaultAllowances))), 60 ether, "allowance");
        assertEq(_word(proxy, bytes32(TOTAL_SUPPLY_SLOT)), PLACEHOLDER_BACKING + PLACEHOLDER_LP_BUDGET, "total supply");
        assertEq(vm.load(proxy, bytes32(NAME_SLOT)), _shortString(PLACEHOLDER_NAME), "name");
        assertEq(vm.load(proxy, bytes32(SYMBOL_SLOT)), _shortString(PLACEHOLDER_SYMBOL), "symbol");
        assertEq(_word(proxy, bytes32(CAP_SLOT)), PLACEHOLDER_CAP, "cap");

        bytes32[] memory roles = _allRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            // RoleData.members is the struct's first field, so it sits at the RoleData slot itself.
            uint256 members = uint256(keccak256(abi.encode(roles[i], ROLES_SLOT)));
            assertEq(_word(proxy, _mappingSlot(address(safe), members)), 1, "Safe is a role member");
            assertEq(_word(proxy, _mappingSlot(deployer, members)), 0, "deployer is not a role member");
        }

        assertEq(_implementationOf(proxy), expectedImplementation, "ERC-1967 implementation slot");
    }

    function _word(address target, bytes32 slot) internal view returns (uint256) {
        return uint256(vm.load(target, slot));
    }

    function _mappingSlot(address key, uint256 mappingSlot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, mappingSlot));
    }

    /// @dev A string shorter than 32 bytes is stored inline: bytes left-aligned, length * 2 in the lowest byte.
    function _shortString(string memory value) internal pure returns (bytes32 word) {
        bytes memory raw = bytes(value);
        require(raw.length < 32, "longer strings are stored out of line");
        for (uint256 i = 0; i < raw.length; i++) {
            word |= bytes32(raw[i]) >> (8 * i);
        }
        word |= bytes32(raw.length * 2);
    }
}
