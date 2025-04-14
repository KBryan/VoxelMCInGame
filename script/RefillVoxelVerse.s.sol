// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Voxel} from "../src/Voxel.sol";
import {VoxelVerseMC} from "../src/VoxelMC.sol";

contract RefillVoxelVerse is Script {
    // To use with environment variables:
    // address public VOXEL_TOKEN_ADDRESS = vm.envAddress("VOXEL_TOKEN_ADDRESS");
    // address public VOXELVERSE_MC_ADDRESS = vm.envAddress("VOXELVERSE_MC_ADDRESS");

    // For direct usage, replace these with your actual deployed addresses:
    address constant VOXEL_TOKEN_ADDRESS = address(0); // Replace with your token address
    address constant VOXELVERSE_MC_ADDRESS = address(0); // Replace with your game contract address

    // Amount of tokens to add in this refill
    uint256 constant REFILL_AMOUNT = 50_000 * 1e18; // 50,000 VOXEL tokens

    function run() external {
        // Start broadcasting transactions
        vm.startBroadcast();

        // Connect to existing contracts
        Voxel voxelToken = Voxel(VOXEL_TOKEN_ADDRESS);
        VoxelVerseMC voxelVerseMC = VoxelVerseMC(VOXELVERSE_MC_ADDRESS);

        // Get balances before refill
        uint256 contractBalanceBefore = voxelToken.balanceOf(VOXELVERSE_MC_ADDRESS);
        uint256 ownerBalanceBefore = voxelToken.balanceOf(msg.sender);

        console.log("Game contract balance before refill:", contractBalanceBefore / 1e18, "VOXEL");
        console.log("Owner balance before refill:", ownerBalanceBefore / 1e18, "VOXEL");
        console.log("Refilling with amount:", REFILL_AMOUNT / 1e18, "VOXEL");

        // Approve the game contract to transfer tokens
        bool approveSuccess = voxelToken.approve(VOXELVERSE_MC_ADDRESS, REFILL_AMOUNT);
        require(approveSuccess, "Failed to approve token transfer");

        // Execute the refill
        voxelVerseMC.refillContract(REFILL_AMOUNT);

        // Get balances after refill
        uint256 contractBalanceAfter = voxelToken.balanceOf(VOXELVERSE_MC_ADDRESS);
        uint256 ownerBalanceAfter = voxelToken.balanceOf(msg.sender);

        console.log("Game contract balance after refill:", contractBalanceAfter / 1e18, "VOXEL");
        console.log("Owner balance after refill:", ownerBalanceAfter / 1e18, "VOXEL");
        console.log("Refill completed successfully!");

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }
}
