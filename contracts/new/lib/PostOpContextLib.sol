// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Constants.sol";

library PostOpContextLib {
    enum NullifierMode {
        ACTIVATION, // ZK proof transaction (first time activation)
        CACHED // Cached transaction (consuming from activated nullifiers)
    }

    struct ActivationContext {
        NullifierMode mode; // 1 byte
        bytes32 userOpHash; // 32 bytes
        uint256 nullifier; // 32 bytes
        uint256 userNullifiersState; // 32 bytes
        address sender; // 20 bytes
    }

    struct CachedContext {
        NullifierMode mode; // 1 byte
        bytes32 userOpHash; // 32 bytes
        uint256 userNullifiersState; // 32 bytes
        address sender; // 20 bytes
    }

    function encodeActivationContext(
        bytes32 userOpHash,
        uint256 nullifier,
        uint256 userNullifiersState,
        address sender
    ) internal pure returns (bytes memory encoded) {
        return
            abi.encodePacked(
                uint8(NullifierMode.ACTIVATION), // 1 byte
                userOpHash, // 32 bytes
                nullifier, // 32 bytes
                userNullifiersState, // 32 bytes
                sender // 20 bytes
            );
        // Total: 117 bytes
    }

    function encodeCachedContext(
        bytes32 userOpHash,
        uint256 userNullifiersState,
        address sender
    ) internal pure returns (bytes memory encoded) {
        return
            abi.encodePacked(
                uint8(NullifierMode.CACHED), // 1 byte
                userOpHash, // 32 bytes
                userNullifiersState, // 32 bytes
                sender // 20 bytes
            );
        // Total: 85 bytes
    }

    function decodeActivationContext(
        bytes calldata context
    ) internal pure returns (ActivationContext memory decoded) {
        require(context.length == 117, "Invalid activation context length");

        assembly {
            let mode := byte(0, calldataload(context.offset))
            mstore(decoded, mode)

            let ptr := add(context.offset, 1)

            mstore(add(decoded, 32), calldataload(ptr)) // userOpHash
            mstore(add(decoded, 64), calldataload(add(ptr, 32))) // nullifier
            mstore(add(decoded, 96), calldataload(add(ptr, 64))) // userNullifiersState

            let senderBytes := calldataload(add(ptr, 96))
            mstore(
                add(decoded, 128),
                and(senderBytes, 0xffffffffffffffffffffffffffffffffffffffff)
            )
        }
    }

    function decodeCachedContext(
        bytes calldata context
    ) internal pure returns (CachedContext memory decoded) {
        require(context.length == 85, "Invalid cached context length");

        assembly {
            let mode := byte(0, calldataload(context.offset))
            mstore(decoded, mode)

            let ptr := add(context.offset, 1)

            mstore(add(decoded, 32), calldataload(ptr)) // userOpHash
            mstore(add(decoded, 64), calldataload(add(ptr, 32))) // userNullifiersState

            let senderBytes := calldataload(add(ptr, 64))
            mstore(
                add(decoded, 96),
                and(senderBytes, 0xffffffffffffffffffffffffffffffffffffffff)
            )
        }
    }
}
