// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library PoolErrors {
    error PoolDoesNotExist(uint256 poolId);
    error PoolAlreadyExists(uint256 poolId);
    error PoolHasNoMembers();
    error InvalidJoiningFee(uint256 provided);
    error IncorrectJoiningFee(uint256 provided, uint256 expected);
    error InsufficientDeposits(uint256 available, uint256 required);
    error MerkleRootNotInHistory(uint32 index, uint32 historyCount);
}
