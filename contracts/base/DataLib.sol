// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Constants.sol";
import "@account-abstraction/contracts/core/UserOperationLib.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PaymasterValidationErrors} from "../errors/PaymasterValidationErrors.sol";
import {PaymasterEncodingErrors} from "../errors/PaymasterEncodingErrors.sol";

/// @title DataLib
/// @notice Library for encoding and decoding paymaster data for standalone paymasters
library DataLib {
    using UserOperationLib for PackedUserOperation;
    /// @notice Pool membership proof structure
    struct PoolMembershipProof {
        uint256 merkleTreeDepth;
        uint256 merkleTreeRoot;
        uint256 nullifier;
        uint256 message;
        uint256 scope;
        uint256[8] points;
    }

    /// @notice Paymaster configuration data (simplified for standalone paymasters)
    struct PaymasterConfig {
        uint32 merkleRootIndex;
        Constants.PaymasterMode mode;
        // 28 bytes reserved for future configuration
    }

    /// @notice Full paymaster data structure
    struct PaymasterData {
        PaymasterConfig config;
        uint256 poolId;
        PoolMembershipProof proof;
    }

    /// @notice Encode paymaster configuration
    /// @param merkleRootIndex Index in the root history
    /// @param mode Paymaster mode (validation or estimation)
    /// @return config Encoded configuration as uint256
    function encodeConfig(
        uint32 merkleRootIndex,
        Constants.PaymasterMode mode
    ) internal pure returns (uint256 config) {
        if (merkleRootIndex >= Constants.POOL_ROOT_HISTORY_SIZE) {
            revert PaymasterValidationErrors.InvalidMerkleRootIndex(
                merkleRootIndex,
                Constants.POOL_ROOT_HISTORY_SIZE
            );
        }

        if (uint8(mode) > 1) {
            revert PaymasterEncodingErrors.InvalidMode(uint8(mode));
        }

        // Pack: merkleRootIndex (bits 0-31) + mode (bits 32-39) + reserved (bits 40-255)
        config = uint256(merkleRootIndex) | (uint256(mode) << 32);
    }

    /// @notice Decode paymaster configuration
    /// @param config Encoded configuration
    /// @return merkleRootIndex Index in the root history
    /// @return mode Paymaster mode
    function decodeConfig(
        uint256 config
    )
        internal
        pure
        returns (uint32 merkleRootIndex, Constants.PaymasterMode mode)
    {
        // Validate unused bits are zero (bits 40-255)
        if (config >> 40 != 0) {
            revert PaymasterEncodingErrors.InvalidConfigFormat(config);
        }

        // Extract merkleRootIndex (bits 0-31)
        merkleRootIndex = uint32(config & type(uint32).max);

        // Extract mode (bits 32-39)
        uint256 modeValue = (config >> 32) & 0xFF;
        mode = Constants.PaymasterMode(modeValue);

        // Validate merkleRootIndex
        if (merkleRootIndex >= Constants.POOL_ROOT_HISTORY_SIZE) {
            revert PaymasterValidationErrors.InvalidMerkleRootIndex(
                merkleRootIndex,
                Constants.POOL_ROOT_HISTORY_SIZE
            );
        }

        // Validate mode
        if (uint8(mode) > 1) {
            revert PaymasterEncodingErrors.InvalidMode(uint8(mode));
        }
    }

    /// @notice Encode complete paymaster data
    /// @param data Paymaster data structure
    /// @return encoded Encoded bytes for paymasterAndData
    function encodePaymasterData(
        PaymasterData memory data
    ) internal pure returns (bytes memory encoded) {
        uint256 config = encodeConfig(
            data.config.merkleRootIndex,
            data.config.mode
        );
        bytes memory encodedProof = abi.encode(data.proof);

        return
            abi.encodePacked(
                config, // 32 bytes
                data.poolId, // 32 bytes
                encodedProof // 416 bytes
            );
    }

    /// @notice Decode paymaster data from UserOperation
    /// @param paymasterAndData The paymasterAndData field from UserOperation
    /// @return data Decoded paymaster data structure
    function decodePaymasterData(
        bytes calldata paymasterAndData
    ) internal pure returns (PaymasterData memory data) {
        if (paymasterAndData.length != Constants.EXPECTED_PAYMASTER_DATA_SIZE) {
            revert PaymasterEncodingErrors.InvalidDataLength(
                paymasterAndData.length,
                Constants.EXPECTED_PAYMASTER_DATA_SIZE
            );
        }

        // Decode config
        uint256 configData = abi.decode(
            paymasterAndData[Constants.CONFIG_OFFSET:Constants.CONFIG_OFFSET +
                Constants.CONFIG_SIZE],
            (uint256)
        );
        (data.config.merkleRootIndex, data.config.mode) = decodeConfig(
            configData
        );

        // Decode poolId
        data.poolId = uint256(
            bytes32(
                paymasterAndData[Constants.POOL_ID_OFFSET:Constants
                    .POOL_ID_OFFSET + Constants.POOL_ID_SIZE]
            )
        );

        // Decode proof
        data.proof = abi.decode(
            paymasterAndData[Constants.PROOF_OFFSET:],
            (PoolMembershipProof)
        );
    }

    /// @notice Extract config from paymaster data
    /// @param paymasterAndData The paymasterAndData field from UserOperation
    /// @return merkleRootIndex Index in the root history
    /// @return mode Paymaster mode
    function extractConfig(
        bytes calldata paymasterAndData
    )
        internal
        pure
        returns (uint32 merkleRootIndex, Constants.PaymasterMode mode)
    {
        if (
            paymasterAndData.length <
            Constants.CONFIG_OFFSET + Constants.CONFIG_SIZE
        ) {
            revert PaymasterEncodingErrors.InvalidDataLength(
                paymasterAndData.length,
                Constants.CONFIG_OFFSET + Constants.CONFIG_SIZE
            );
        }

        uint256 configData = abi.decode(
            paymasterAndData[Constants.CONFIG_OFFSET:Constants.CONFIG_OFFSET +
                Constants.CONFIG_SIZE],
            (uint256)
        );

        return decodeConfig(configData);
    }

    /// @notice Extract only poolId from paymaster data
    /// @param paymasterAndData The paymasterAndData field from UserOperation
    /// @return poolId The pool ID
    function extractPoolId(
        bytes calldata paymasterAndData
    ) internal pure returns (uint256 poolId) {
        if (
            paymasterAndData.length <
            Constants.POOL_ID_OFFSET + Constants.POOL_ID_SIZE
        ) {
            revert PaymasterEncodingErrors.InvalidDataLength(
                paymasterAndData.length,
                Constants.POOL_ID_OFFSET + Constants.POOL_ID_SIZE
            );
        }

        return
            uint256(
                bytes32(
                    paymasterAndData[Constants.POOL_ID_OFFSET:Constants
                        .POOL_ID_OFFSET + Constants.POOL_ID_SIZE]
                )
            );
    }

    /// @notice Check if paymaster data is in estimation mode
    /// @param paymasterAndData The paymasterAndData field from UserOperation
    /// @return isEstimation True if in estimation mode
    function isEstimationMode(
        bytes calldata paymasterAndData
    ) internal pure returns (bool isEstimation) {
        (, Constants.PaymasterMode mode) = extractConfig(paymasterAndData);
        return mode == Constants.PaymasterMode.ESTIMATION;
    }

    /// @notice Generate stub data for gas estimation
    /// @param poolId Pool ID
    /// @param merkleRootIndex Root index to use
    /// @param currentRoot Current merkle tree root
    /// @return stubData Encoded stub data
    function generateStubData(
        uint256 poolId,
        uint32 merkleRootIndex,
        uint256 currentRoot
    ) internal pure returns (bytes memory stubData) {
        PaymasterData memory data;

        // Set config for estimation mode
        data.config.merkleRootIndex = merkleRootIndex;
        data.config.mode = Constants.PaymasterMode.ESTIMATION;

        // Set pool ID
        data.poolId = poolId;

        // Create dummy proof
        data.proof = PoolMembershipProof({
            merkleTreeDepth: Constants.MIN_DEPTH,
            merkleTreeRoot: currentRoot,
            nullifier: 0,
            message: 0,
            scope: poolId,
            points: [uint256(0), 0, 0, 0, 0, 0, 0, 0]
        });

        return encodePaymasterData(data);
    }

    /// @notice Validate paymaster data structure
    /// @param paymasterAndData The paymasterAndData field from UserOperation
    /// @return isValid True if data structure is valid
    function validatePaymasterAndData(
        bytes calldata paymasterAndData
    ) internal pure returns (bool isValid) {
        // Basic length check
        if (paymasterAndData.length != Constants.EXPECTED_PAYMASTER_DATA_SIZE) {
            return false;
        }

        // Check if we can extract config without reverting
        if (
            paymasterAndData.length <
            Constants.CONFIG_OFFSET + Constants.CONFIG_SIZE
        ) {
            return false;
        }

        // Validate config format manually
        uint256 configData = abi.decode(
            paymasterAndData[Constants.CONFIG_OFFSET:Constants.CONFIG_OFFSET +
                Constants.CONFIG_SIZE],
            (uint256)
        );

        // Check unused bits are zero (bits 40-255) - reduced from 48 since no PaymasterType
        if (configData >> 40 != 0) {
            return false;
        }

        // Check merkleRootIndex is valid
        uint32 merkleRootIndex = uint32(configData & type(uint32).max);
        if (merkleRootIndex >= Constants.POOL_ROOT_HISTORY_SIZE) {
            return false;
        }

        // Check mode is valid (0 or 1)
        uint256 modeValue = (configData >> 32) & 0xFF;
        if (modeValue > 1) {
            return false;
        }

        // Basic poolId check (should be extractable)
        if (
            paymasterAndData.length <
            Constants.POOL_ID_OFFSET + Constants.POOL_ID_SIZE
        ) {
            return false;
        }

        return true;
    }

    /// @notice Hash function compatible with SNARK scalar modulus
    function _hash(uint256 message) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(message))) >> 8;
    }

    /// @notice Internal function to compute the message hash for a UserOperation.
    /// @dev This hash is used for verifying the ZKP against the UserOp content.
    /// @param userOp The PackedUserOperation to hash.
    /// @return The computed message hash.
    function _getMessageHash(
        PackedUserOperation calldata userOp,
        IEntryPoint entryPoint
    ) internal view returns (bytes32) {
        address sender = userOp.getSender();
        return
            keccak256(
                abi.encode(
                    keccak256(
                        abi.encode(
                            sender,
                            userOp.nonce,
                            keccak256(userOp.initCode),
                            keccak256(userOp.callData),
                            userOp.accountGasLimits,
                            userOp.preVerificationGas,
                            userOp.gasFees,
                            keccak256(
                                // Only hash the portion of paymasterAndData *before* the custom data
                                userOp.paymasterAndData[:Constants
                                    .PAYMASTER_DATA_OFFSET]
                            )
                        )
                    ),
                    entryPoint,
                    block.chainid
                )
            );
    }

    /// @notice Generate cached stub data for gas estimation with pre-computed nullifier range
    /// @param poolId The pool ID
    /// @return stubData Encoded cached stub data in ESTIMATION mode
    function generateCachedStubData(
        uint256 poolId
    ) internal pure returns (bytes memory stubData) {
        // Format: poolId + mode + startIndex + endIndex
        return
            abi.encodePacked(
                poolId, // 32 bytes
                Constants.PaymasterMode.ESTIMATION,
                uint8(0),
                uint8(Constants.MAX_NULLIFIERS_PER_ADDRESS - 1)
            );
    }

    // Add to DataLib.sol
    /// @notice Pack two uint8 indices into a single uint256
    /// @param startIndex The start index (0-7)
    /// @param endIndex The end index (0-7)
    /// @return packed The packed indices as uint256
    function packIndices(
        uint8 startIndex,
        uint8 endIndex
    ) internal pure returns (uint256 packed) {
        return (uint256(startIndex) << 8) | uint256(endIndex);
    }

    /// @notice Unpack two uint8 indices from a uint256
    /// @param packed The packed indices
    /// @return startIndex The start index
    /// @return endIndex The end index
    function unpackIndices(
        uint256 packed
    ) internal pure returns (uint8 startIndex, uint8 endIndex) {
        startIndex = uint8(packed >> 8);
        endIndex = uint8(packed & 0xFF);
    }

    function getUserStateKey(
        uint256 poolId,
        address sender
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, sender));
    }
}
