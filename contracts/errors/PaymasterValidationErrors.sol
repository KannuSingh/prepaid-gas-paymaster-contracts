// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library PaymasterValidationErrors {
    error InvalidPaymasterData();
    error NullifierAlreadyUsed(uint256 nullifier);
    error UserExceededGasFund();
    error InsufficientPoolFund();
    error InsufficientPaymasterFund();
    error InvalidMerkleRootIndex(uint32 index, uint32 maxIndex);
    error InvalidMerkleTreeRoot(uint256 provided, uint256 expected);
    error MerkleTreeDepthUnsupported(
        uint256 provided,
        uint256 min,
        uint256 max
    );
    error InvalidProofMessage(uint256 provided, uint256 expected);
    error InvalidProofScope(uint256 provided, uint256 expected);
    error ProofVerificationFailed();
    error InvalidStubContextLength(uint256 providedLength);

    error SenderNotCached(address sender, uint256 poolId);
    /// @notice Error thrown when nullifier range is invalid
    /// @param startIndex The provided start index
    /// @param endIndex The provided end index
    error InvalidNullifierIndexRange(uint8 startIndex, uint8 endIndex);

    /// @notice Error thrown when all nullifier slots are active so can't add activate new one(have remaining balance)
    error AllNullifierSlotsActive();
}
