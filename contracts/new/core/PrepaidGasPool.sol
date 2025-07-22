// file:prepaid-gas-paymaster-contracts/contracts/new/core/PrepaidGasPool.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Constants} from "../lib/Constants.sol";

import {IPrepaidGasPool} from "../interfaces/IPrepaidGasPool.sol";

import {State} from "./State.sol";

import {PrepaidGasLib} from "../lib/PrepaidGasLib.sol";

/**
 * @title PrepaidGasPool
 * @notice Allows publicly depositing funds.
 * @dev Deposits can be irreversibly suspended by the Entrypoint.
 */
abstract contract PrepaidGasPool is State, IPrepaidGasPool {
    /**
     * @notice Initializes the contract state addresses
     * @param _joiningAmount Amount needed to join this pool
     * @param _membershipVerifier Address of the Groth16 verifier for withdrawal proofs
     */
    constructor(
        uint256 _joiningAmount,
        address _membershipVerifier
    ) State(_joiningAmount, _membershipVerifier) {}

    /*///////////////////////////////////////////////////////////////
                             USER METHODS 
  //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPrepaidGasPool
    function deposit(uint256 _commitment) external payable {
        // Check deposits are enabled
        if (dead) revert PoolIsDead();
        uint256 _value = msg.value;
        if (_value >= type(uint128).max && _value != JOINING_AMOUNT)
            revert InvalidJoiningAmount();

        // Insert commitment in state (revert if already present)
        _insert(_commitment);

        totalDeposit += _value;

        // Pull funds from caller
        _pull(msg.sender, _value);

        emit Deposited(msg.sender, _commitment);
    }

    /// @notice Internal proof validation logic using the external verifier contract.
    /// @param proof The pool membership proof data.
    /// @return True if the proof is valid, false otherwise.
    function _validateProof(
        PrepaidGasLib.PoolMembershipProof memory proof
    ) internal view returns (bool) {
        // Call the external verifier contract to verify the proof.
        return
            MEMBERSHIP_VERIFIER.verifyProof(
                [proof.points[0], proof.points[1]],
                [
                    [proof.points[2], proof.points[3]],
                    [proof.points[4], proof.points[5]]
                ],
                [proof.points[6], proof.points[7]],
                [
                    proof.merkleTreeRoot,
                    proof.nullifier,
                    PrepaidGasLib._hash(proof.message),
                    PrepaidGasLib._hash(proof.scope)
                ],
                proof.merkleTreeDepth
            );
    }

    /**
     * @notice Handle receiving an asset
     * @dev To be implemented by an asset specific contract
     * @param _sender The address of the user sending funds
     * @param _value The amount of asset being received
     */
    function _pull(address _sender, uint256 _value) internal virtual;

    /**
     * @notice Handle sending an asset
     * @dev To be implemented by an asset specific contract
     * @param _recipient The address of the user receiving funds
     * @param _value The amount of asset being sent
     */
    function _push(address _recipient, uint256 _value) internal virtual;
}
