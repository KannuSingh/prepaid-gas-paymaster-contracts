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
}
