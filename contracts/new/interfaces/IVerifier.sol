// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVerifier
/// @notice Interface of the Groth16 verifier contracts
interface IVerifier {
    /// @notice Verify a privacy proof
    /// @param _pA Proof point A
    /// @param _pB Proof point B
    /// @param _pC Proof point C
    /// @param _pubSignals Public signals
    /// @param merkleTreeDepth Depth of the Merkle tree
    /// @return result True if proof is valid
    function verifyProof(
        uint[2] memory _pA,
        uint[2][2] memory _pB,
        uint[2] memory _pC,
        uint[4] memory _pubSignals,
        uint256 merkleTreeDepth
    ) external view returns (bool result);
}
