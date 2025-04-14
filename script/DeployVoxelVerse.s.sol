// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Voxel} from "../src/Voxel.sol";
import {VoxelVerseMC} from "../src/VoxelMC.sol";

contract DeployVoxelVerse is Script {
    // Amount of tokens to initially transfer to the game contract
    uint256 constant INITIAL_GAME_FUNDS = 100_000 * 1e18; // 100,000 VOXEL tokens

    // Amount of tokens to drip per day per player
    uint256 constant DAILY_DRIP_AMOUNT = 10 * 1e18; // 10 VOXEL tokens

    function run() external {
        // Start broadcasting transactions
        vm.startBroadcast();

        // 1. Deploy the VoxelToken contract
        Voxel voxelToken = new Voxel();
        console.log("VoxelToken deployed at:", address(voxelToken));
        console.log("Total supply: 21,000,000 VOXEL");

        // 2. Deploy the VoxelVerseMC contract with token address and drip amount
        VoxelVerseMC voxelVerseMC = new VoxelVerseMC(address(voxelToken), DAILY_DRIP_AMOUNT);
        console.log("VoxelVerseMC deployed at:", address(voxelVerseMC));
        console.log("Daily drip amount:", DAILY_DRIP_AMOUNT / 1e18, "VOXEL");
        console.log("Free mint limit:", voxelVerseMC.FREE_MINT_LIMIT(), "NFTs");
        console.log("Paid mint price:", voxelVerseMC.MINT_PRICE() / 1e18, "VOXEL");

        // 3. Transfer initial tokens to the game contract
        bool transferSuccess = voxelToken.transfer(address(voxelVerseMC), INITIAL_GAME_FUNDS);
        require(transferSuccess, "Failed to fund game contract");
        console.log("Transferred", INITIAL_GAME_FUNDS / 1e18, "VOXEL to game contract");

        // 4. Verify balances
        uint256 contractBalance = voxelToken.balanceOf(address(voxelVerseMC));
        uint256 ownerBalance = voxelToken.balanceOf(msg.sender);
        console.log("Game contract balance:", contractBalance / 1e18, "VOXEL");
        console.log("Owner remaining balance:", ownerBalance / 1e18, "VOXEL");

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }
}
