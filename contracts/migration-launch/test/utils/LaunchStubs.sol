// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev The getters MigrationLaunch's constructor reads from the settler, nothing else.
contract StubSettler {
    address public immutable SAFE;
    address public immutable V1;
    address public immutable V2;
    address public immutable WETH;

    constructor(address safe, address v1, address v2, address weth) {
        SAFE = safe;
        V1 = v1;
        V2 = v2;
        WETH = weth;
    }
}

/// @dev The getters MigrationLaunch's constructor reads from the vault, nothing else.
contract StubVault {
    address internal immutable OWNER;
    address internal immutable TOKEN_V1;
    address internal immutable TOKEN_V2;

    constructor(address owner_, address v1, address v2) {
        OWNER = owner_;
        TOKEN_V1 = v1;
        TOKEN_V2 = v2;
    }

    function owner() external view returns (address) {
        return OWNER;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function V1() external view returns (address) {
        return TOKEN_V1;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function V2() external view returns (address) {
        return TOKEN_V2;
    }
}
