// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MigrationVault} from "@surplus/migration/src/MigrationVault.sol";

interface IRehearsalVm {
    function envAddress(string calldata name) external view returns (address);
    function envUint(string calldata name) external view returns (uint256);
    function envString(string calldata name) external view returns (string memory);
    function parseJsonAddressArray(string calldata json, string calldata key) external pure returns (address[] memory);
    function readFile(string calldata path) external view returns (string memory);
    function startBroadcast(address signer) external;
    function stopBroadcast() external;
}

/**
 * @notice REHEARSAL ONLY, for a private anvil. It deploys a vault and has real holders deposit, so that the
 *         kit's snapshot phase can be proven against real chain logs. The holders are impersonated
 *         (`--unlocked`), which only an anvil fork allows. It is never a launch step.
 * @dev    Run with `forge script … --broadcast --unlocked --sender <deployer> --rpc-url <private anvil>`.
 *         REHEARSAL_HOLDERS is a JSON file {"holders": [..]}; each deposits half its live balance, then a
 *         quarter of it again, then withdraws a tenth of its balance, so the ledger has net ≠ credited.
 */
contract RehearsalDeposits {
    IRehearsalVm internal constant vm = IRehearsalVm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    IERC20 internal constant V1 = IERC20(0xC52aeDec3374422d7510E294cfAa90799595CBa3);

    function run() external returns (address vault) {
        address deployer = vm.envAddress("REHEARSAL_DEPLOYER");
        address owner = vm.envAddress("REHEARSAL_OWNER");
        uint256 depositDeadline = vm.envUint("REHEARSAL_DEPOSIT_DEADLINE");
        address[] memory holders = vm.parseJsonAddressArray(vm.readFile(vm.envString("REHEARSAL_HOLDERS")), ".holders");

        vm.startBroadcast(deployer);
        // The v2 slot only has to hold an address with code; the snapshot reads the ledger, not the token.
        vault = address(
            new MigrationVault(
                V1,
                IERC20(address(V1)),
                depositDeadline,
                depositDeadline + 3 days,
                7 days,
                180 days,
                10_000,
                true,
                owner
            )
        );
        vm.stopBroadcast();

        for (uint256 i; i < holders.length; ++i) {
            address h = holders[i];
            uint256 balance = V1.balanceOf(h);
            require(balance >= 10, "holder has no v1");
            vm.startBroadcast(h);
            require(V1.approve(vault, balance), "approve");
            MigrationVault(vault).deposit(balance / 2);
            MigrationVault(vault).deposit(balance / 4);
            MigrationVault(vault).withdrawV1(balance / 10);
            vm.stopBroadcast();
        }
    }
}
