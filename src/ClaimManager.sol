// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ActionManager} from "./ActionManager.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title ClaimManager
/// @dev Provides reusable claim-based logic for minting, XP rewards, etc. with signature verification
abstract contract ClaimManager is EIP712 {
    string private constant SIGNING_DOMAIN = "VoxelVerseMC";
    string private constant SIGNATURE_VERSION = "1";

    mapping(address => uint256) public nonces;

    constructor() EIP712(SIGNING_DOMAIN, SIGNATURE_VERSION) {}

    // --- STRUCTS ---

    struct MintVoucher {
        address user;
        uint256 tokenId;
        uint256 expiry;
        uint256 nonce;
    }

    struct XPClaim {
        address user;
        uint256 tokenId;
        uint256 xpAmount;
        uint256 nonce;
    }

    function hashAction(ActionManager.Action calldata action) public pure virtual returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("Action(address user,string actionType,uint256 tokenId,uint256 nonce)"),
                action.user,
                keccak256(bytes(action.actionType)),
                action.tokenId,
                action.nonce
            )
        );
    }

    function verifyAction(ActionManager.Action calldata action, bytes calldata sig, address expectedSigner)
        public
        view
        returns (bool)
    {
        bytes32 digest = _hashTypedDataV4(hashAction(action));
        return ECDSA.recover(digest, sig) == expectedSigner;
    }

    function useAction(ActionManager.Action calldata action, bytes calldata sig, address trustedSigner)
        internal
        virtual
    {
        require(action.user == msg.sender, "Not your action");
        require(action.nonce == nonces[msg.sender], "Invalid nonce");
        require(verifyAction(action, sig, trustedSigner), "Bad signature");
        nonces[msg.sender]++;
    }

    // --- HASHING ---

    function hashMintVoucher(MintVoucher calldata v) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("MintVoucher(address user,uint256 tokenId,uint256 expiry,uint256 nonce)"),
                v.user,
                v.tokenId,
                v.expiry,
                v.nonce
            )
        );
    }

    function hashXPClaim(XPClaim calldata claim) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("XPClaim(address user,uint256 tokenId,uint256 xpAmount,uint256 nonce)"),
                claim.user,
                claim.tokenId,
                claim.xpAmount,
                claim.nonce
            )
        );
    }

    // --- VERIFICATION ---

    function verifyMintVoucher(MintVoucher calldata v, bytes calldata sig, address expectedSigner)
        public
        view
        returns (bool)
    {
        bytes32 digest = _hashTypedDataV4(hashMintVoucher(v));
        return ECDSA.recover(digest, sig) == expectedSigner;
    }

    function verifyXPClaim(XPClaim calldata claim, bytes calldata sig, address expectedSigner)
        public
        view
        returns (bool)
    {
        bytes32 digest = _hashTypedDataV4(hashXPClaim(claim));
        return ECDSA.recover(digest, sig) == expectedSigner;
    }

    // --- CONSUMPTION FUNCTIONS ---

    function getMaxVoucherExpiry() public view virtual returns (uint256);

    function useMintVoucher(MintVoucher calldata v, bytes calldata sig, address trustedSigner) internal {
        require(block.timestamp <= v.expiry, "Voucher expired");
        require(v.expiry <= block.timestamp + getMaxVoucherExpiry(), "Voucher expiry too far in future");

        require(v.user == msg.sender, "Not your voucher");
        require(v.nonce == nonces[msg.sender], "Invalid nonce");
        require(verifyMintVoucher(v, sig, trustedSigner), "Bad signature");
        nonces[msg.sender]++;
    }

    function useXPClaim(XPClaim calldata claim, bytes calldata sig, address trustedSigner) internal {
        require(claim.user == msg.sender, "Not your claim");
        require(claim.nonce == nonces[msg.sender], "Invalid nonce");
        require(verifyXPClaim(claim, sig, trustedSigner), "Bad signature");
        nonces[msg.sender]++;
    }

    // --- HELPER ---
    function getUserNonce(address user) public view returns (uint256) {
        return nonces[user];
    }

    function getXPClaimDigest(XPClaim calldata claim) public view returns (bytes32) {
        return _hashTypedDataV4(hashXPClaim(claim));
    }
}
