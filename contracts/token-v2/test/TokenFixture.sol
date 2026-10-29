// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SurplusTokenV2} from "../src/SurplusTokenV2.sol";
import {GovernanceDouble} from "./GovernanceDouble.sol";
import {Test} from "./Base.t.sol";

/// @notice Representative append-only successor: it keeps the whole V2 layout and adds state after it.
contract SurplusTokenV2Revision is SurplusTokenV2 {
    uint256 public marker;

    /// @dev Run through `upgradeToAndCall`, so the new state is set in the upgrade transaction itself.
    function initializeRevision(uint256 marker_) external reinitializer(2) onlyRole(UPGRADER_ROLE) {
        marker = marker_;
    }
}

/// @notice Deploys the token the way launch does: the implementation, then an ERC1967Proxy that runs
///         `initialize` in its constructor, both sent by a deployer that must end up holding nothing.
abstract contract TokenFixture is Test {
    // Stand-ins for the launch kit's params.json values, which are not decided yet.
    string internal constant PLACEHOLDER_NAME = "PLACEHOLDER Surplus v2";
    string internal constant PLACEHOLDER_SYMBOL = "PLACEHOLDER";
    uint256 internal constant PLACEHOLDER_CAP = 1_000_000 ether;
    uint256 internal constant PLACEHOLDER_BACKING = 600_000 ether;
    uint256 internal constant PLACEHOLDER_LP_BUDGET = 250_000 ether;

    // Local copies, so no external getter runs between vm.expectRevert and the call it watches.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Fixed by ERC-1967, not by the compiler.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    SurplusTokenV2 internal implementation;
    SurplusTokenV2 internal token;
    GovernanceDouble internal safe;

    address internal deployer;
    address internal signerQuorum;
    address internal vault;
    address internal launchHelper;
    address internal stranger;

    function setUp() public virtual {
        vm.chainId(8453);
        deployer = _account(0xD3, "deployer");
        signerQuorum = _account(0x5A, "signerQuorum");
        vault = _account(0x7A, "vault");
        launchHelper = _account(0x1A, "launchHelper");
        stranger = _account(0xBAD, "stranger");

        safe = new GovernanceDouble(signerQuorum);
        vm.label(address(safe), "safe");

        vm.startPrank(deployer);
        implementation = new SurplusTokenV2();
        token = _deployProxy(PLACEHOLDER_NAME, PLACEHOLDER_SYMBOL, PLACEHOLDER_CAP, address(safe));
        vm.stopPrank();
    }

    function _deployProxy(string memory name_, string memory symbol_, uint256 cap_, address governance)
        internal
        returns (SurplusTokenV2)
    {
        bytes memory init = abi.encodeCall(SurplusTokenV2.initialize, (name_, symbol_, cap_, governance));
        return SurplusTokenV2(address(new ERC1967Proxy(address(implementation), init)));
    }

    /// @dev The token's part of the launch batch: both mints in one Safe transaction.
    function _launchMintCalls(uint256 backing, uint256 lpBudget)
        internal
        view
        returns (GovernanceDouble.Call[] memory calls)
    {
        calls = new GovernanceDouble.Call[](2);
        calls[0] = _tokenCall(abi.encodeCall(SurplusTokenV2.mint, (vault, backing)));
        calls[1] = _tokenCall(abi.encodeCall(SurplusTokenV2.mint, (launchHelper, lpBudget)));
    }

    function _launchMints(uint256 backing, uint256 lpBudget) internal {
        _safeBatch(_launchMintCalls(backing, lpBudget));
    }

    function _safeCall(bytes memory data) internal {
        _safeBatch(_single(data));
    }

    function _safeCallReverts(bytes memory data, bytes memory reason) internal {
        _safeBatchReverts(_single(data), reason);
    }

    function _safeBatch(GovernanceDouble.Call[] memory calls) internal {
        vm.prank(signerQuorum);
        safe.execute(calls);
    }

    function _safeBatchReverts(GovernanceDouble.Call[] memory calls, bytes memory reason) internal {
        vm.prank(signerQuorum);
        vm.expectRevert(reason);
        safe.execute(calls);
    }

    function _single(bytes memory data) internal view returns (GovernanceDouble.Call[] memory calls) {
        calls = new GovernanceDouble.Call[](1);
        calls[0] = _tokenCall(data);
    }

    function _tokenCall(bytes memory data) internal view returns (GovernanceDouble.Call memory) {
        return GovernanceDouble.Call({target: address(token), data: data});
    }

    /// @dev OZ 4.9 AccessControl's exact revert reason, so a test cannot pass on an unrelated revert.
    function _missingRole(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(account),
            " is missing role ",
            Strings.toHexString(uint256(role), 32)
        );
    }

    function _allRoles() internal pure returns (bytes32[] memory roles) {
        roles = new bytes32[](4);
        roles[0] = DEFAULT_ADMIN_ROLE;
        roles[1] = MINTER_ROLE;
        roles[2] = BURNER_ROLE;
        roles[3] = UPGRADER_ROLE;
    }

    function _account(uint256 key, string memory name) internal returns (address account) {
        account = vm.addr(key);
        vm.label(account, name);
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }
}
