// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

abstract contract ActionManager is EIP712 {
    struct Action {
        address user;
        string actionType;
        uint256 tokenId;
        uint256 nonce;
    }

    function hashAction(Action calldata action) public pure virtual returns (bytes32) {
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

    function verifyActionSignature(Action calldata action, bytes calldata sig, address expectedSigner)
        public
        view
        returns (bool)
    {
        bytes32 digest = _hashTypedDataV4(hashAction(action)); // combines domain separator + struct hash
        return ECDSA.recover(digest, sig) == expectedSigner;
    }
}
