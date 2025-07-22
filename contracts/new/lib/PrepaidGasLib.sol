// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@account-abstraction/contracts/core/UserOperationLib.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

/// @title PrepaidGasLib
library PrepaidGasLib {
    using UserOperationLib for PackedUserOperation;

    /*///////////////////////////////////////////////////////////////
                              STRUCT
    //////////////////////////////////////////////////////////////*/
    /// @notice Paymaster operation modes
    enum PaymasterMode {
        VALIDATION, // 0 - Normal validation mode
        ESTIMATION // 1 - Gas estimation mode
    }

    /// @notice Paymaster configuration data (simplified for standalone paymasters)
    struct PaymasterConfig {
        uint32 merkleRootIndex;
        PaymasterMode mode;
        // 28 bytes reserved for future configuration
    }
    /// @notice Pool membership proof structure
    struct PoolMembershipProof {
        uint256 merkleTreeDepth;
        uint256 merkleTreeRoot;
        uint256 nullifier;
        uint256 message;
        uint256 scope;
        uint256[8] points;
    }
    struct ActivationPaymasterData {
        PaymasterConfig config;
        PoolMembershipProof proof;
    }
    /*///////////////////////////////////////////////////////////////
                              Constants
    //////////////////////////////////////////////////////////////*/
    uint256 internal constant PAYMASTER_DATA_OFFSET = 52;
    uint256 internal constant MEMBERSHIP_PROOF_OFFSET =
        PAYMASTER_DATA_OFFSET + CONFIG_SIZE; // 84
    uint256 internal constant CONFIG_SIZE = 32;
    uint256 internal constant MEMBERSHIP_PROOF_SIZE = 416; // 5 uint256 + 8 uint256 array
    uint256 internal constant ACTIVATION_PAYMASTER_DATA_SIZE =
        PAYMASTER_DATA_OFFSET + CONFIG_SIZE + MEMBERSHIP_PROOF_SIZE;
    uint256 internal constant CACHED_PAYMASTER_DATA_SIZE = 53;

    /// @notice Decode paymaster data from UserOperation
    /// @param paymasterAndData The paymasterAndData field from UserOperation
    /// @return data Decoded paymaster data structure
    function _decodeActivationPaymasterData(
        bytes calldata paymasterAndData
    ) internal pure returns (ActivationPaymasterData memory data) {
        // Decode config
        uint256 configData = abi.decode(
            paymasterAndData[PAYMASTER_DATA_OFFSET:PAYMASTER_DATA_OFFSET +
                CONFIG_SIZE],
            (uint256)
        );
        (data.config.merkleRootIndex, data.config.mode) = decodeConfig(
            configData
        );

        // Decode proof
        data.proof = abi.decode(
            paymasterAndData[MEMBERSHIP_PROOF_OFFSET:],
            (PoolMembershipProof)
        );
    }

    /// @notice Decode paymaster configuration
    /// @param config Encoded configuration
    /// @return merkleRootIndex Index in the root history
    /// @return mode Paymaster mode
    function decodeConfig(
        uint256 config
    ) internal pure returns (uint32 merkleRootIndex, PaymasterMode mode) {
        // Extract merkleRootIndex (bits 0-31)
        merkleRootIndex = uint32(config & type(uint32).max);

        // Extract mode (bits 32-39)
        uint256 modeValue = (config >> 32) & 0xFF;
        mode = PaymasterMode(modeValue);
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
                                userOp.paymasterAndData[:PAYMASTER_DATA_OFFSET]
                            )
                        )
                    ),
                    entryPoint,
                    block.chainid
                )
            );
    }
}
