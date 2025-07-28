// file:prepaid-gas-paymaster-contracts/contracts/new/implementation/OneTimeUsePaymaster.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/BasePaymaster.sol";
import "../core/PrepaidGasPool.sol";
import "@account-abstraction/contracts/core/Helpers.sol";
import "@account-abstraction/contracts/core/UserOperationLib.sol";
import {PrepaidGasLib} from "../lib/PrepaidGasLib.sol";

/// @title OneTimeUsePaymaster
contract OneTimeUsePaymaster is BasePaymaster, PrepaidGasPool {
    using UserOperationLib for PackedUserOperation;

    /*///////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/
    event UserOpSponsoredWithNullifier(
        address indexed sender,
        bytes32 indexed userOpHash,
        uint256 actualGasCost,
        uint256 nullifierUsed
    );
    event RevenueWithdrawn(address withdrawAddress, uint256 amount);

    /*///////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/
    error InvalidDataLength();
    error InsufficientPaymasterFund();
    error UserOpExceedsGasAmount();
    error PoolHasNoMembers();
    error MessageMismatch();
    error ProofVerificationFailed();
    error NullifierAlreadyUsed();
    error InsufficientPostOpGasLimit();

    /*///////////////////////////////////////////////////////////////
                              STATE
    //////////////////////////////////////////////////////////////*/
    /// @notice Mapping to track used nullifiers.
    /// The nullifier identifies a unique one-time use instance linked to a pool membership.
    mapping(uint256 => bool) public usedNullifiers;

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

            // === Check post-op gas limit ===
            uint128 postOpGasLimit = PrepaidGasLib._extractPostOpGasLimit(
                userOp.paymasterAndData
            );
            if (postOpGasLimit < Constants.POSTOP_GAS_COST && isValidationMode) {
                revert InsufficientPostOpGasLimit();
            }

            // This is the core "one-time use" logic.
            if (usedNullifiers[data.proof.nullifier] && isValidationMode) {
                revert NullifierAlreadyUsed();
            }

            // === Check paymaster's deposit balance ===
            if (getDeposit() < maxCost && isValidationMode) {
                revert InsufficientPaymasterFund();
            }

            // === Check if joining fee is sufficient ===
            if ((JOINING_AMOUNT < maxCost) && isValidationMode) {
                revert UserOpExceedsGasAmount();
            }

            // === Pool has members (merkleTreeSize) ===
            if (_merkleTree.size == 0 && isValidationMode) {
                revert PoolHasNoMembers();
            }

            // === Check merkleTreeDepth ===
            if (
                (data.proof.merkleTreeDepth < MIN_TREE_DEPTH ||
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
        // Decode context:  userOpHash, nullifier, sender.
        (bytes32 userOpHash, uint256 nullifier, address sender) = abi.decode(
            context,
            (bytes32, uint256, address)
        );
        //  Mark nullifier as used
        usedNullifiers[nullifier] = true;
        // Calculate total cost, including postOp overhead.
        uint256 postOpGasCost = Constants.POSTOP_GAS_COST *
            actualUserOpFeePerGas;
        uint256 totalGasCost = actualGasCost + postOpGasCost;

        // Deduct the JOINING_AMOUNT from the pool's total deposits.
        totalDeposit -= JOINING_AMOUNT;

        emit UserOpSponsoredWithNullifier(
            sender,
            userOpHash,
            totalGasCost,
            nullifier
        );
    }

    function _pull(
        address /*_sender*/,
        uint256 _amount
    ) internal virtual override(PrepaidGasPool) {
        if (msg.value != _amount) revert InsufficientValue();
        _depositToEntryPoint(msg.value);
    }

    /// @notice Override to allow revenue withdrawal
    function _withdrawTo(
        address payable withdrawAddress,
        uint256 amount
    ) internal virtual override(BasePaymaster) {
        uint256 currentEntryPointDeposit = getDeposit();
        uint256 revenue = currentEntryPointDeposit - totalDeposit;

        if (amount == 0 || amount > revenue) {
            revert WithdrawalNotAllowed();
        }

        entryPoint.withdrawTo(withdrawAddress, amount);
        emit RevenueWithdrawn(withdrawAddress, amount);
    }

    /// @notice Get available revenue
    function getRevenue() public view returns (uint256) {
        uint256 currentEntryPointDeposit = getDeposit();
        return currentEntryPointDeposit - totalDeposit;
    }
}
