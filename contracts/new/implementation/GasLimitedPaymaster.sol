// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/BasePaymaster.sol";
import "../core/PrepaidGasPool.sol";
import "@account-abstraction/contracts/core/Helpers.sol";
import "@account-abstraction/contracts/core/UserOperationLib.sol";
import {PrepaidGasLib} from "../lib/PrepaidGasLib.sol";

/// @title OneTimeUsePaymaster
contract GasLimitedPaymaster is BasePaymaster, PrepaidGasPool {
    using UserOperationLib for PackedUserOperation;

    /*///////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/
    event UserOpSponsored(
        bytes32 indexed userOpHash,
        address indexed sender,
        uint256 actualGasCost
    );
    /*///////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/
    error InvalidDataLength();
    error InsufficientPaymasterFund();
    error UserOpExceedsGasAmount();
    error PoolHasNoMembers();
    error MessageMismatch();
    error ProofVerificationFailed();

    /*///////////////////////////////////////////////////////////////
                              STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice User gas usage tracking per nullifier
    mapping(uint256 => uint256) public nullifierGasUsage;

    constructor(
        uint256 _joiningAmount,
        IEntryPoint _entryPoint,
        address _membershipVerifier
    )
        BasePaymaster(_entryPoint)
        PrepaidGasPool(_joiningAmount, _membershipVerifier)
    {}

    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    )
        internal
        virtual
        override
        returns (bytes memory context, uint256 validationData)
    {
        if (
            userOp.paymasterAndData.length ==
            PrepaidGasLib.ACTIVATION_PAYMASTER_DATA_SIZE
        ) {
            PrepaidGasLib.ActivationPaymasterData memory data = PrepaidGasLib
                ._decodeActivationPaymasterData(userOp.paymasterAndData);
            bool isValidationMode = data.config.mode ==
                PrepaidGasLib.PaymasterMode.VALIDATION;
            address sender = userOp.getSender();

            // === Check paymaster's deposit balance ===
            if (getDeposit() < maxCost && isValidationMode) {
                revert InsufficientPaymasterFund();
            }

            // === Check if nullifier remainining gas is sufficient ===
            if (
                ((JOINING_AMOUNT - nullifierGasUsage[data.proof.nullifier]) <
                    maxCost) && isValidationMode
            ) {
                revert UserOpExceedsGasAmount();
            }

            // === Pool has members (merkleTreeSize) ===
            if (_merkleTree.size == 0 && isValidationMode) {
                revert PoolHasNoMembers();
            }

            // === Check merkleTreeDepth ===
            if (
                (data.proof.merkleTreeDepth < MAX_TREE_DEPTH ||
                    data.proof.merkleTreeDepth > MAX_TREE_DEPTH) &&
                isValidationMode
            ) {
                revert InvalidTreeDepth();
            }

            // === Root from history ===
            uint256 expectedRoot = roots[data.config.merkleRootIndex];
            if (
                (data.proof.merkleTreeRoot != expectedRoot ||
                    expectedRoot == 0) && isValidationMode
            ) {
                revert UnknownStateRoot();
            }

            // === Check proof scope ===
            if ((data.proof.scope != SCOPE) && isValidationMode) {
                revert ScopeMismatch();
            }

            // === Check proof message ===
            bytes32 messageHash = PrepaidGasLib._getMessageHash(
                userOp,
                entryPoint
            );
            if (
                (data.proof.message != uint256(messageHash)) && isValidationMode
            ) {
                revert MessageMismatch();
            }

            if (!_validateProof(data.proof) && isValidationMode) {
                revert ProofVerificationFailed();
            }

            // === Return appropriate context ===
            if (!isValidationMode) {
                return (
                    abi.encode(userOpHash, data.proof.nullifier, sender),
                    Constants.VALIDATION_FAILED
                );
            }

            return (
                abi.encode(userOpHash, data.proof.nullifier, sender),
                _packValidationData(false, 0, 0)
            );
        } else {
            revert InvalidDataLength();
        }
    }

    function _postOp(
        PostOpMode /*mode*/,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) internal virtual override {
        // Decode the nullifier, userOpHash, sender from the context passed during validation.
        (bytes32 userOpHash, uint256 nullifier, address sender) = abi.decode(
            context,
            (bytes32, uint256, address)
        );

        // Calculate the total gas cost, including the EntryPoint's postOp overhead.
        uint256 postOpGasCost = Constants.POSTOP_GAS_COST *
            actualUserOpFeePerGas;
        uint256 totalGasCost = actualGasCost + postOpGasCost;

        // Deduct the gas cost from the user's allowance tracked by their nullifier.
        nullifierGasUsage[nullifier] += totalGasCost;

        // Deduct from the global tracker of user deposits for revenue calculation.
        totalDeposit -= totalGasCost;

        emit UserOpSponsored(userOpHash, sender, totalGasCost);
    }

    function _pull(
        address /*_sender*/,
        uint256 _amount
    ) internal virtual override(PrepaidGasPool) {
        if (msg.value != _amount) revert InsufficientValue();
        _depositToEntryPoint(msg.value);
    }

    function _push(
        address _recipient,
        uint256 _value
    ) internal virtual override(PrepaidGasPool) {}
}
