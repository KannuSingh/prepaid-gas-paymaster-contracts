// file:prepaid-gas-paymaster-contracts/contracts/new/lib/Constants.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Constants
/// @notice Shared constants for the standalone paymaster system
library Constants {
    uint256 constant SNARK_SCALAR_FIELD =
        21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617;

    /// @notice Maximum number of nullifiers that can be cached per user(sender address) per pool
    uint8 internal constant MAX_NULLIFIERS_PER_ADDRESS = 2;

    // Validation and gas constants
    uint256 internal constant VALIDATION_FAILED = 1;

    uint256 internal constant POSTOP_GAS_COST = 65000;
    uint256 internal constant POSTOP_ACTIVATION_GAS_COST = 86650;
    uint256 internal constant POSTOP_CACHE_GAS_COST = 45000;
}
