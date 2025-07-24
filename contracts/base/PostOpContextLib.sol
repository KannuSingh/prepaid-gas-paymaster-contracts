// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Constants.sol";

/// @title PostOpContextLib
/// @notice Library for efficiently encoding and decoding postOp context data
/// @dev Uses encodePacked for gas optimization and includes pre-computed state to avoid recalculation
library PostOpContextLib {
    /// @notice Unified context data for both activation and cached flows
    /// @dev The nullifierOrJoiningFee field is interpreted based on the mode:
    ///      - ACTIVATION mode: represents the nullifier
    ///      - CACHED mode: represents the joiningFee
    struct Context {
        Constants.NullifierMode mode; // 1 byte
        uint256 poolId; // 32 bytes
        bytes32 userOpHash; // 32 bytes
        uint256 nullifierOrJoiningFee; // 32 bytes (nullifier for ACTIVATION, joiningFee for CACHED)
        uint256 userNullifiersState; // 32 bytes
        bytes32 userStateKey; // 32 bytes
        address sender; // 20 bytes
    }

    /// @notice Encode activation context using encodePacked for gas efficiency
    /// @param poolId The pool ID
    /// @param userOpHash The user operation hash
    /// @param nullifier The nullifier from the proof
    /// @param userNullifiersState The pre-computed user nullifier state
    /// @param userStateKey The pre-computed user state key
    /// @param sender The sender address
    /// @return encoded The packed context bytes
    function encodeActivationContext(
        uint256 poolId,
        bytes32 userOpHash,
        uint256 nullifier,
        uint256 userNullifiersState,
        bytes32 userStateKey,
        address sender
    ) internal pure returns (bytes memory encoded) {
        return
            abi.encodePacked(
                uint8(Constants.NullifierMode.ACTIVATION), // 1 byte
                poolId, // 32 bytes
                userOpHash, // 32 bytes
                nullifier, // 32 bytes (nullifierOrJoiningFee)
                userNullifiersState, // 32 bytes
                userStateKey, // 32 bytes
                sender // 20 bytes
            );
        // Total: 181 bytes
    }

    /// @notice Encode cached context using encodePacked for gas efficiency
    /// @param poolId The pool ID
    /// @param userOpHash The user operation hash
    /// @param joiningFee The pool's joining fee
    /// @param userNullifiersState The pre-computed user nullifier state
    /// @param userStateKey The pre-computed user state key
    /// @param sender The sender address
    /// @return encoded The packed context bytes
    function encodeCachedContext(
        uint256 poolId,
        bytes32 userOpHash,
        uint256 joiningFee,
        uint256 userNullifiersState,
        bytes32 userStateKey,
        address sender
    ) internal pure returns (bytes memory encoded) {
        return
            abi.encodePacked(
                uint8(Constants.NullifierMode.CACHED), // 1 byte
                poolId, // 32 bytes
                userOpHash, // 32 bytes
                joiningFee, // 32 bytes (nullifierOrJoiningFee)
                userNullifiersState, // 32 bytes
                userStateKey, // 32 bytes
                sender // 20 bytes
            );
        // Total: 181 bytes
    }

    /// @notice Decode the unified context from packed bytes
    /// @param context The packed context bytes
    /// @return decoded The decoded unified context
    function decodeContext(
        bytes calldata context
    ) internal pure returns (Context memory decoded) {
        require(context.length == 181, "Invalid context length");

        // Manually slice the packed data at correct byte positions
        assembly {
            // mode (byte 0) - store as uint256 in memory
            let mode := byte(0, calldataload(context.offset))
            mstore(decoded, mode)

            let ptr := add(context.offset, 1)

            // poolId (bytes 1-32) -> memory offset 32
            mstore(add(decoded, 32), calldataload(ptr))

            // userOpHash (bytes 33-64) -> memory offset 64
            mstore(add(decoded, 64), calldataload(add(ptr, 32)))

            // nullifierOrJoiningFee (bytes 65-96) -> memory offset 96
            mstore(add(decoded, 96), calldataload(add(ptr, 64)))

            // userNullifiersState (bytes 97-128) -> memory offset 128
            mstore(add(decoded, 128), calldataload(add(ptr, 96)))

            // userStateKey (bytes 129-160) -> memory offset 160
            mstore(add(decoded, 160), calldataload(add(ptr, 128)))

            // sender (bytes 161-180) -> memory offset 192
            // Load 32 bytes starting from byte 160, then mask to get only the 20 bytes
            let senderBytes := calldataload(add(ptr, 160))
            mstore(
                add(decoded, 192),
                and(senderBytes, 0xffffffffffffffffffffffffffffffffffffffff)
            )
        }
    }
}
