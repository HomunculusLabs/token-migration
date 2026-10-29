// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @notice Stands in for the governance Safe. The token only ever sees `msg.sender == this contract`,
///         and a batch is all-or-nothing, like a Safe transaction routed through MultiSendCallOnly.
/// @dev Not a Safe: no signers, threshold, nonce or signature checks. The single `operator` models
///      "the signers reached threshold". The real Safe is rehearsed separately (SUR-662).
contract GovernanceDouble {
    struct Call {
        address target;
        bytes data;
    }

    address public immutable operator;

    constructor(address operator_) {
        operator = operator_;
    }

    /// @dev Bubbles the first failing call's revert data, so the whole batch reverts with it.
    function execute(Call[] calldata calls) external {
        require(msg.sender == operator, "GovernanceDouble: not operator");
        for (uint256 i = 0; i < calls.length; i++) {
            Address.functionCall(calls[i].target, calls[i].data);
        }
    }
}
