// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Voxel} from "../src/Voxel.sol";
import {VoxelVerseMC} from "../src/VoxelMC.sol";

contract IntegrationTests is Test {
    Voxel public voxelToken;
    VoxelVerseMC public voxelVerseMC;

    address public deployer = address(1);
    address public user1 = address(2);
    address public user2 = address(3);

    uint256 public constant DAILY_DRIP = 10 * 10 ** 18;
    uint256 public constant INITIAL_FUND = 1_000_000 * 10 ** 18;

    // Setup function - runs before each test
    function setUp() public {
        vm.startPrank(deployer);

        // Deploy VoxelToken
        voxelToken = new Voxel();

        // Deploy VoxelVerseMC
        voxelVerseMC = new VoxelVerseMC(address(voxelToken), DAILY_DRIP);

        // Fund VoxelVerseMC with some tokens
        voxelToken.transfer(address(voxelVerseMC), INITIAL_FUND);

        // Give users some VOXEL tokens for testing
        voxelToken.transfer(user1, 10_000 * 10 ** 18);
        voxelToken.transfer(user2, 10_000 * 10 ** 18);

        vm.stopPrank();
    }

    // --- INTEGRATION TESTS ---

    function testFullLifecycle() public {
        // 1. User mints an NFT
        vm.startPrank(user1);
        voxelVerseMC.mintCharacterNFT();
        uint256 tokenId = 0;

        // 2. Check initial balance (starting tokens)
        uint256 startingBonus = 10 * 10 ** 18;
        uint256 expectedBalance = 10_000 * 10 ** 18 + startingBonus;
        assertEq(voxelToken.balanceOf(user1), expectedBalance, "User should have starting tokens");

        // 3. Claim daily rewards for a week
        for (uint256 i = 0; i < 7; i++) {
            // Advance time by 1 day
            vm.warp(block.timestamp + 1 days);

            // Claim drip
            voxelVerseMC.claimDrip(tokenId);

            // Update expected balance
            expectedBalance += DAILY_DRIP;
            assertEq(voxelToken.balanceOf(user1), expectedBalance, "Balance should increase with drips");
        }

        // 4. Check NFT metadata after week of play
        (,,,,,, uint256 daysSurvived,,,) = voxelVerseMC.nftHolderAttributes(tokenId);
        assertEq(daysSurvived, 1, "Days survived should be unchanged"); // Note: This only changes via updateCharacterAttributes

        vm.stopPrank();

        // 5. Admin updates character attributes
        vm.startPrank(deployer);

        // Get current attributes
        (
            string memory name,
            string memory imageURI,
            uint256 happiness,
            uint256 thirst,
            uint256 hunger,
            uint256 xp,
            ,
            uint256 characterLevel,
            uint256 health,
            uint256 heat
        ) = voxelVerseMC.nftHolderAttributes(tokenId);

        // Update days survived and XP
        VoxelVerseMC.CharacterAttributes memory updatedAttrs = VoxelVerseMC.CharacterAttributes({
            name: name,
            imageURI: imageURI,
            happiness: happiness,
            thirst: thirst,
            hunger: hunger,
            xp: xp + 100,
            daysSurvived: 7,
            characterLevel: characterLevel + 1,
            health: health,
            heat: heat
        });

        voxelVerseMC.updateCharacterAttributes(tokenId, updatedAttrs);
        vm.stopPrank();

        // 6. Verify updated attributes
        (,,,,, uint256 newXp, uint256 newDays, uint256 newLevel,,) = voxelVerseMC.nftHolderAttributes(tokenId);
        assertEq(newXp, xp + 100, "XP should be updated");
        assertEq(newDays, 7, "Days survived should be updated");
        assertEq(newLevel, characterLevel + 1, "Level should be updated");
    }

    function testSystemStressTest() public {
        // Simulate many users minting and claiming
        uint256 numUsers = 100;
        address[] memory users = new address[](numUsers);

        // Create and fund users
        for (uint256 i = 0; i < numUsers; i++) {
            users[i] = address(uint160(10000 + i));
            vm.deal(users[i], 1 ether); // Give ETH for gas

            // Paid mints will need tokens after the free mint limit
            if (i >= 250) {
                vm.prank(deployer);
                voxelToken.transfer(users[i], 2000 * 10 ** 18); // Enough for paid mint

                vm.prank(users[i]);
                voxelToken.approve(address(voxelVerseMC), 1000 * 10 ** 18);
            }
        }

        // Mint NFTs for all users
        for (uint256 i = 0; i < numUsers; i++) {
            vm.prank(users[i]);
            voxelVerseMC.mintCharacterNFT();
        }

        // Check that all users have an NFT
        for (uint256 i = 0; i < numUsers; i++) {
            assertEq(voxelVerseMC.balanceOf(users[i]), 1, "User should have an NFT");
        }

        // Simulate claiming over time - fast forward 30 days
        for (uint256 day = 0; day < 30; day++) {
            // Advance time by 1 day
            vm.warp(block.timestamp + 1 days);

            // Random subset of users claim each day (simulating real usage patterns)
            for (uint256 i = 0; i < numUsers; i++) {
                // 70% chance to claim on any given day
                if (uint256(keccak256(abi.encodePacked(day, i, block.timestamp))) % 100 < 70) {
                    vm.prank(users[i]);
                    voxelVerseMC.claimDrip(i); // tokenId == i for this test
                }
            }
        }

        // Check contract token balance after stress test
        uint256 expectedUsed = numUsers * 10 * 10 ** 18; // Starting tokens for everyone

        // Not all users claimed every day, but most claimed most days, so this is approximate
        uint256 approximateRewards = numUsers * 30 * DAILY_DRIP * 7 / 10; // Approximately 70% claim rate

        // Add the paid mint revenue
        uint256 paidMints = numUsers > 250 ? (numUsers - 250) * 1000 * 10 ** 18 : 0;

        // Check the contract still has enough funds
        assertTrue(
            voxelToken.balanceOf(address(voxelVerseMC)) < INITIAL_FUND - expectedUsed - approximateRewards + paidMints,
            "Contract should have distributed a significant amount of tokens"
        );

        // Verify contract still has funds for future operations
        assertTrue(voxelToken.balanceOf(address(voxelVerseMC)) > 0, "Contract should still have some tokens");
    }

    function testFreeToPaidMintTransition() public {
        // First, mint 249 NFTs
        for (uint256 i = 0; i < 249; i++) {
            address freeUser = address(uint160(20000 + i));
            vm.deal(freeUser, 1 ether);

            vm.prank(freeUser);
            voxelVerseMC.mintCharacterNFT();
        }

        // Check remaining free mints
        assertEq(voxelVerseMC.getRemainingFreeMints(), 1, "Should have 1 free mint left");
        assertEq(voxelVerseMC.getCurrentMintPrice(), 0, "Current mint price should be 0");

        // Use the last free mint
        address lastFreeUser = address(30000);
        vm.deal(lastFreeUser, 1 ether);

        vm.prank(lastFreeUser);
        voxelVerseMC.mintCharacterNFT();

        // Verify transition to paid mints
        assertEq(voxelVerseMC.getRemainingFreeMints(), 0, "Should have 0 free mints left");
        assertEq(voxelVerseMC.getCurrentMintPrice(), 1000 * 10 ** 18, "Current mint price should be 1000 VOXEL");

        // Now test a paid mint
        address paidUser = address(40000);
        vm.deal(paidUser, 1 ether);

        // Send tokens to the paid user
        vm.prank(deployer);
        voxelToken.transfer(paidUser, 2000 * 10 ** 18);

        // Approve and mint
        vm.startPrank(paidUser);
        voxelToken.approve(address(voxelVerseMC), 1000 * 10 ** 18);
        voxelVerseMC.mintCharacterNFT();
        vm.stopPrank();

        // Verify user paid and received NFT
        assertEq(voxelVerseMC.balanceOf(paidUser), 1, "Paid user should have an NFT");

        // User should have initial balance (2000) - mint price (1000) + starting bonus (10)
        assertEq(voxelToken.balanceOf(paidUser), 1010 * 10 ** 18, "Paid user should have correct token balance");
    }

    function testContractRefillFlow() public {
        // First, create a test NFT so we have a valid token ID
        address testUser = address(1234);
        vm.deal(testUser, 1 ether);
        vm.prank(testUser);
        voxelVerseMC.mintCharacterNFT();

        // Now drain the contract funds using a direct token transfer
        uint256 contractBalance = voxelToken.balanceOf(address(voxelVerseMC));
        uint256 drainAmount = contractBalance - 1000 * 10 ** 18; // Keep some tokens in the contract

        // Execute the drain by spoofing the contract address (only in testing)
        vm.prank(address(voxelVerseMC));
        voxelToken.transfer(deployer, drainAmount);

        // Get current balance after draining
        uint256 balanceBefore = voxelToken.balanceOf(address(voxelVerseMC));

        // Refill the contract
        uint256 refillAmount = 500_000 * 10 ** 18;

        vm.startPrank(deployer);
        voxelToken.approve(address(voxelVerseMC), refillAmount);
        voxelVerseMC.refillContract(refillAmount);
        vm.stopPrank();

        // Verify balance increased
        assertEq(
            voxelToken.balanceOf(address(voxelVerseMC)),
            balanceBefore + refillAmount,
            "Contract balance should increase by refill amount"
        );

        // Test user minting still works
        address newUser = address(50000);
        vm.deal(newUser, 1 ether);

        vm.prank(newUser);
        voxelVerseMC.mintCharacterNFT(); // Should work with refilled tokens

        // Verify user got an NFT
        assertEq(voxelVerseMC.balanceOf(newUser), 1, "User should have an NFT after refill");
    }
}
