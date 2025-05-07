// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Voxel} from "../src/Voxel.sol";
import {VoxelVerseMC, TooEarlyToClaim} from "../src/VoxelMC.sol";
import {ClaimManager} from "../src/ClaimManager.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract IntegrationTests is Test {
    Voxel public voxelToken;
    VoxelVerseMC public voxelVerseMC;

    address public deployer = address(1);
    address public user1 = address(2);
    address public user2 = address(3);

    uint256 public constant DECIMALS = 1e18;
    uint256 public constant STARTING_BONUS = 10 * DECIMALS;
    uint256 public constant DAILY_DRIP = 10 * DECIMALS;
    uint256 public constant MINT_PRICE = 1000 * DECIMALS;
    uint256 public constant INITIAL_FUND = 1_000_000 * DECIMALS;
    uint256 public constant REVIVE_COST = 10 * DECIMALS;

    uint256 private trustedPrivateKey = 0xA11CE;
    address private trustedSigner = vm.addr(trustedPrivateKey);

    function setUp() public {
        vm.startPrank(deployer);
        voxelToken = new Voxel(deployer);
        voxelVerseMC = new VoxelVerseMC(address(voxelToken), DAILY_DRIP);
        voxelVerseMC.setTrustedSigner(trustedSigner);
        voxelVerseMC.grantRole(voxelVerseMC.EDITOR_ROLE(), deployer);
        voxelToken.transfer(address(voxelVerseMC), INITIAL_FUND);
        voxelToken.transfer(user1, 10_000 * DECIMALS);
        voxelToken.transfer(user2, 10_000 * DECIMALS);
        vm.stopPrank();
    }

    function getXp(uint256 tokenId) internal view returns (uint256 xp) {
        (,,,,, xp,,,,) = voxelVerseMC.nftHolderAttributes(tokenId);
    }

    function testClaimXPWithSignature() public {
        vm.startPrank(user1);
        voxelVerseMC.mintCharacterNFT();
        uint256 tokenId = 0;
        uint256 startingXp = getXp(tokenId);
        vm.stopPrank();
        uint256 cap = voxelVerseMC.xpCapPerDay();

        ClaimManager.XPClaim memory claim = ClaimManager.XPClaim({
            user: user1,
            tokenId: tokenId,
            xpAmount: cap,
            nonce: voxelVerseMC.getUserNonce(user1)
        });

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("XPClaim(address user,uint256 tokenId,uint256 xpAmount,uint256 nonce)"),
                claim.user,
                claim.tokenId,
                claim.xpAmount,
                claim.nonce
            )
        );

        bytes32 digest = voxelVerseMC.exposedHashTypedDataV4(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(trustedPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(user1);
        voxelVerseMC.claimXPReward(claim, signature);

        uint256 newXp = getXp(tokenId);
        assertEq(newXp, startingXp + cap, "XP should be increased by claim amount");
    }

    function testMintCharacterWithValidVoucher() public {
        ClaimManager.MintVoucher memory voucher = ClaimManager.MintVoucher({
            user: user1,
            tokenId: 0,
            expiry: block.timestamp + voxelVerseMC.getMaxVoucherExpiry(),
            nonce: voxelVerseMC.getUserNonce(user1)
        });

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("MintVoucher(address user,uint256 tokenId,uint256 expiry,uint256 nonce)"),
                voucher.user,
                voucher.tokenId,
                voucher.expiry,
                voucher.nonce
            )
        );

        bytes32 digest = voxelVerseMC.exposedHashTypedDataV4(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(trustedPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(user1);
        voxelVerseMC.mintCharacterWithVoucher(voucher, signature);

        assertEq(voxelVerseMC.balanceOf(user1), 1, "User should own 1 NFT");
        assertEq(voxelVerseMC.getUserNonce(user1), 1, "Nonce should be incremented");
        assertGt(voxelToken.balanceOf(user1), 0, "User should receive starting tokens");

        vm.expectRevert("Invalid nonce");
        vm.prank(user1);
        voxelVerseMC.mintCharacterWithVoucher(voucher, signature);
    }

    function testReviveCharacter() public {
        vm.startPrank(user1);
        voxelVerseMC.mintCharacterNFT();
        uint256 tokenId = 0;
        vm.stopPrank();

        vm.startPrank(deployer);
        voxelVerseMC.updateCharacterAttributes(
            tokenId,
            VoxelVerseMC.CharacterAttributes({
                name: "ReviveMe",
                imageURI: "",
                happiness: 0,
                thirst: 0,
                hunger: 0,
                xp: 0,
                daysSurvived: 0,
                characterLevel: 1,
                health: 0,
                heat: 0
            })
        );
        vm.stopPrank();

        vm.startPrank(user1);
        voxelToken.approve(address(voxelVerseMC), voxelVerseMC.reviveCost());
        voxelVerseMC.reviveCharacter(tokenId);

        (,,,,,,,, uint256 health,) = voxelVerseMC.nftHolderAttributes(tokenId);
        assertEq(health, 100, "Character should be revived with full health");
        vm.stopPrank();
    }

    function testFullLifecycle() public {
        vm.startPrank(user1);
        voxelVerseMC.mintCharacterNFT();
        uint256 tokenId = 0;

        uint256 expectedBalance = 10_000 * DECIMALS + STARTING_BONUS;
        assertEq(voxelToken.balanceOf(user1), expectedBalance, "User should have starting tokens");

        uint256 currentTime = block.timestamp;
        for (uint256 i = 0; i < 7; i++) {
            currentTime += 1 days;
            vm.warp(currentTime);
            voxelVerseMC.claimDrip(tokenId);
            expectedBalance += DAILY_DRIP;
            assertEq(voxelToken.balanceOf(user1), expectedBalance, "Balance should increase with drips");
        }

        (,,,,,, uint256 daysSurvived,,,) = voxelVerseMC.nftHolderAttributes(tokenId);
        assertEq(daysSurvived, 1, "Days survived should be unchanged");
        vm.stopPrank();

        vm.startPrank(deployer);
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

        VoxelVerseMC.CharacterAttributes memory updatedAttrs = VoxelVerseMC.CharacterAttributes({
            name: name,
            imageURI: imageURI,
            happiness: uint16(happiness),
            thirst: uint16(thirst),
            hunger: uint16(hunger),
            xp: uint16(xp + 100),
            daysSurvived: 7,
            characterLevel: uint16(characterLevel + 1),
            health: uint16(health),
            heat: uint16(heat)
        });

        voxelVerseMC.updateCharacterAttributes(tokenId, updatedAttrs);
        vm.stopPrank();

        (,,,,, uint256 newXp, uint256 newDays, uint256 newLevel,,) = voxelVerseMC.nftHolderAttributes(tokenId);
        assertEq(newXp, xp + 100, "XP should be updated");
        assertEq(newDays, 7, "Days survived should be updated");
        assertEq(newLevel, characterLevel + 1, "Level should be updated");
    }

    function testCannotClaimTwiceInOneDay() public {
        vm.startPrank(user1);
        voxelVerseMC.mintCharacterNFT();
        uint256 tokenId = 0;

        vm.warp(block.timestamp + 1 days);
        voxelVerseMC.claimDrip(tokenId);

        vm.expectRevert(
            abi.encodeWithSelector(TooEarlyToClaim.selector, tokenId, block.timestamp + voxelVerseMC.dripCooldown())
        );
        voxelVerseMC.claimDrip(tokenId);
    }

    function testFreeToPaidMintTransition() public {
        for (uint256 i = 0; i < 249; i++) {
            address freeUser = address(uint160(20000 + i));
            vm.deal(freeUser, 1 ether);
            vm.prank(freeUser);
            voxelVerseMC.mintCharacterNFT();
        }

        assertEq(voxelVerseMC.getRemainingFreeMints(), 1, "Should have 1 free mint left");
        assertEq(voxelVerseMC.getCurrentMintPrice(), 0, "Current mint price should be 0");

        address lastFreeUser = address(30000);
        vm.deal(lastFreeUser, 1 ether);
        vm.prank(lastFreeUser);
        voxelVerseMC.mintCharacterNFT();

        assertEq(voxelVerseMC.getRemainingFreeMints(), 0, "Should have 0 free mints left");
        assertEq(voxelVerseMC.getCurrentMintPrice(), MINT_PRICE, "Current mint price should be 1000 VOXEL");

        address paidUser = address(40000);
        vm.deal(paidUser, 1 ether);
        vm.prank(deployer);
        voxelToken.transfer(paidUser, 2000 * DECIMALS);

        vm.startPrank(paidUser);
        voxelToken.approve(address(voxelVerseMC), MINT_PRICE);
        voxelVerseMC.mintCharacterNFT();
        vm.stopPrank();

        assertEq(voxelVerseMC.balanceOf(paidUser), 1, "Paid user should have an NFT");
        assertEq(voxelToken.balanceOf(paidUser), 1010 * DECIMALS, "Paid user should have correct token balance");
    }

    function testContractRefillFlow() public {
        address testUser = address(1234);
        vm.deal(testUser, 1 ether);
        vm.prank(testUser);
        voxelVerseMC.mintCharacterNFT();

        uint256 contractBalance = voxelToken.balanceOf(address(voxelVerseMC));
        uint256 drainAmount = contractBalance - 1000 * DECIMALS;
        vm.prank(address(voxelVerseMC));
        voxelToken.transfer(deployer, drainAmount);

        uint256 balanceBefore = voxelToken.balanceOf(address(voxelVerseMC));
        uint256 refillAmount = 500_000 * DECIMALS;

        vm.startPrank(deployer);
        voxelToken.approve(address(voxelVerseMC), refillAmount);
        voxelVerseMC.refillContract(refillAmount);
        vm.stopPrank();

        assertEq(
            voxelToken.balanceOf(address(voxelVerseMC)),
            balanceBefore + refillAmount,
            "Contract balance should increase by refill amount"
        );

        address newUser = address(50000);
        vm.deal(newUser, 1 ether);
        vm.prank(newUser);
        voxelVerseMC.mintCharacterNFT();
        assertEq(voxelVerseMC.balanceOf(newUser), 1, "User should have an NFT after refill");
    }

    function testDripDecayBasedOnMissedDays() public {
        vm.startPrank(user1);
        voxelVerseMC.mintCharacterNFT();
        uint256 tokenId = 0;
        uint256 expectedBalance = voxelToken.balanceOf(user1);

        // Warp forward 1 day — claim normally
        vm.warp(block.timestamp + 1 days);
        voxelVerseMC.claimDrip(tokenId);
        expectedBalance += DAILY_DRIP;
        assertEq(voxelToken.balanceOf(user1), expectedBalance, "Day 1: normal drip");

        // Warp forward 3 days — 2 days missed
        vm.warp(block.timestamp + 3 days);
        voxelVerseMC.claimDrip(tokenId);

        // Calculate expected decay (e.g., base - 2 * decayRate)
        uint256 decayRate = 1 * DECIMALS;
        uint256 expectedDecay = 2 * decayRate;
        uint256 decayedDrip = DAILY_DRIP > expectedDecay ? DAILY_DRIP - expectedDecay : 0;

        expectedBalance += decayedDrip;
        assertEq(voxelToken.balanceOf(user1), expectedBalance, "Day 4: decayed drip after missed days");
        vm.stopPrank();
    }
}
