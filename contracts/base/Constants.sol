// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Constants
/// @notice Shared constants for the standalone paymaster system
library Constants {
    /// @notice Paymaster operation modes
    enum PaymasterMode {
        VALIDATION, // 0 - Normal validation mode
        ESTIMATION // 1 - Gas estimation mode
    }

    enum NullifierMode {
        ACTIVATION, // ZK proof transaction (first time activation)
        CACHED // Cached transaction (consuming from activated nullifiers)
    }

    // EIP-4337 Paymaster data structure offsets
    uint256 internal constant PAYMASTER_VALIDATION_GAS_OFFSET = 20;
    uint256 internal constant PAYMASTER_POSTOP_GAS_OFFSET = 36;
    uint256 internal constant PAYMASTER_DATA_OFFSET = 52;

    // Pool configuration constants
    uint32 internal constant POOL_ROOT_HISTORY_SIZE = 64;

    // Paymaster data structure sizes
    uint256 internal constant CONFIG_SIZE = 32;
    uint256 internal constant POOL_ID_SIZE = 32;
    uint256 internal constant PRIVACY_PROOF_SIZE = 416; // 5 uint256 + 8 uint256 array

    // Paymaster data offsets
    uint256 internal constant CONFIG_OFFSET = PAYMASTER_DATA_OFFSET; // 52
    uint256 internal constant POOL_ID_OFFSET =
        PAYMASTER_DATA_OFFSET + CONFIG_SIZE; // 84
    uint256 internal constant PROOF_OFFSET =
        PAYMASTER_DATA_OFFSET + CONFIG_SIZE + POOL_ID_SIZE; // 116

    uint256 internal constant EXPECTED_PAYMASTER_DATA_SIZE =
        PAYMASTER_DATA_OFFSET + CONFIG_SIZE + POOL_ID_SIZE + PRIVACY_PROOF_SIZE;

    // Cached paymaster data size (paymaster address + verification gas + postop gas + poolId + mode +startIndex+endIndex)
    uint256 internal constant CACHED_PAYMASTER_DATA_SIZE = 87;
    // Cached paymaster data size (paymaster address + verification gas + postop gas + poolId + mode )
    uint256 internal constant SIMPLE_CACHED_PAYMASTER_DATA_SIZE = 85;

    /// @notice Maximum number of nullifiers that can be cached per user(sender address) per pool
    uint8 internal constant MAX_NULLIFIERS_PER_ADDRESS = 2;

    // Validation and gas constants
    uint256 internal constant VALIDATION_FAILED = 1;

    uint256 internal constant POSTOP_GAS_COST = 65000;
    uint256 internal constant POSTOP_ACTIVATION_GAS_COST = 86650;
    uint256 internal constant POSTOP_CACHE_GAS_COST = 45000;

    // Merkle tree constraints
    uint256 internal constant MIN_DEPTH = 1;
    uint256 internal constant MAX_DEPTH = 32;
}
