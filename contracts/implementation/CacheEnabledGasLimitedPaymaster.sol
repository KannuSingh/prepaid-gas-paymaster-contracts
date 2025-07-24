// file:prepaid-gas-paymaster-contracts/contracts/new/implementation/CacheEnabledGasLimitedPaymaster.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/BasePaymaster.sol";
import "../core/PrepaidGasPool.sol";
import "@account-abstraction/contracts/core/Helpers.sol";
import "@account-abstraction/contracts/core/UserOperationLib.sol";
import {NullifierCacheStateLib} from "../lib/NullifierCacheStateLib.sol";
import {PostOpContextLib} from "../lib/PostOpContextLib.sol";
import {PrepaidGasLib} from "../lib/PrepaidGasLib.sol";

// import "hardhat/console.sol";

/// @title CacheEnabledGasLimitedPaymaster
contract CacheEnabledGasLimitedPaymaster is BasePaymaster, PrepaidGasPool {
    using UserOperationLib for PackedUserOperation;
    using NullifierCacheStateLib for uint256;

    /*///////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/
    event UserOpSponsored(
        address indexed sender,
        bytes32 indexed userOpHash,
        uint256 actualGasCost
    );
    event RevenueWithdrawn(address withdrawAddress, uint256 amount);
    event NullifierConsumed(
        bytes32 indexed userOpHash,
        uint256 indexed nullifier,
        uint256 gasUsed,
        uint8 index
    );

    /*///////////////////////////////////////////////////////////////
                              ERRORS
  //////////////////////////////////////////////////////////////*/
    error InvalidDataLength();
    error SenderNotCached();
    error InsufficientPaymasterFund();
    error UserOpExceedsGasAmount();
    error AllNullifierSlotsActive();
    error PoolHasNoMembers();
    error MessageMismatch();
    error ProofVerificationFailed();

    /*///////////////////////////////////////////////////////////////
                              State
  //////////////////////////////////////////////////////////////*/
    /// @notice Cache mapping: sender => packed state flags
    mapping(address => uint256) public userNullifiersStates;
    /// @notice Cache mapping: keccak(abi.encode(sender,index)) => nullifier)
    mapping(bytes32 => uint256) public userNullifiers;
    /// @notice nullifier gas usage tracking : nullifier => gasUsed
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
            PrepaidGasLib.CACHED_PAYMASTER_DATA_SIZE
        ) {
            //Cache Flow
            return _validateCachedPaymasterUserOp(userOp, userOpHash, maxCost);
        } else if (
            userOp.paymasterAndData.length ==
            PrepaidGasLib.ACTIVATION_PAYMASTER_DATA_SIZE
        ) {
            // Activation flow via zkProof
            return
                _validateActivationPaymasterUserOp(userOp, userOpHash, maxCost);
        } else {
            revert InvalidDataLength();
        }
    }

    function _validateCachedPaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) internal virtual returns (bytes memory context, uint256 validationData) {
        address sender = userOp.getSender();

        // === Extract mode from paymasterAndData field ===
        bytes memory data = userOp.paymasterAndData[PrepaidGasLib
            .PAYMASTER_DATA_OFFSET:];

        bool isValidationMode = uint8(data[0]) ==
            uint8(PrepaidGasLib.PaymasterMode.VALIDATION);

        // === Get cached nullifier state ===
        uint256 userNullifiersState = userNullifiersStates[sender];
        if (
            userNullifiersState.getActivatedNullifierCount() == 0 &&
            isValidationMode
        ) {
            revert SenderNotCached();
        }

        // === Check paymaster's deposit balance ===
        if (getDeposit() < maxCost && isValidationMode) {
            revert InsufficientPaymasterFund();
        }

        // === Calculate total available gas using activeNullifierIndex ===
        uint256 totalAvailable = _calculateAvailableGasWithActiveIndex(
            sender,
            userNullifiersState
        );

        // === Check if sufficient gas available ===
        if (totalAvailable < maxCost && isValidationMode) {
            revert UserOpExceedsGasAmount();
        }

        if (!isValidationMode) {
            return (
                PostOpContextLib.encodeCachedContext(
                    userOpHash,
                    userNullifiersState,
                    sender
                ),
                Constants.VALIDATION_FAILED
            );
        }

        return (
            PostOpContextLib.encodeCachedContext(
                userOpHash,
                userNullifiersState,
                sender
            ),
            _packValidationData(false, 0, 0)
        );
    }

    /// @notice Calculate total available gas starting from activeNullifierIndex with wraparound
    /// @param sender The user's nullifier state key
    /// @param userNullifiersState The user's nullifier state
    /// @return totalAvailable Total available gas across active nullifiers
    function _calculateAvailableGasWithActiveIndex(
        address sender,
        uint256 userNullifiersState
    ) internal view returns (uint256 totalAvailable) {
        uint8 activatedCount = userNullifiersState.getActivatedNullifierCount();
        uint8 startIndex = userNullifiersState.getActiveNullifierIndex();

        // Calculate available gas for each active nullifier
        for (uint8 i = 0; i < activatedCount; i++) {
            uint8 index = (startIndex + i) %
                Constants.MAX_NULLIFIERS_PER_ADDRESS;
            bytes32 userStateKey = keccak256(abi.encode(sender, index));
            uint256 nullifier = userNullifiers[userStateKey];

            if (nullifier == 0) {
                return 0; // Empty slot
            }

            uint256 used = nullifierGasUsage[nullifier];
            totalAvailable = JOINING_AMOUNT > used ? JOINING_AMOUNT - used : 0;
        }
    }

    function _validateActivationPaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) internal virtual returns (bytes memory context, uint256 validationData) {
        PrepaidGasLib.ActivationPaymasterData memory data = PrepaidGasLib
            ._decodeActivationPaymasterData(userOp.paymasterAndData);
        bool isValidationMode = data.config.mode ==
            PrepaidGasLib.PaymasterMode.VALIDATION;
        address sender = userOp.getSender();

        uint256 userNullifiersState = userNullifiersStates[sender];

        // Check if we can add new nullifier
        if (
            userNullifiersState.getActivatedNullifierCount() >=
            Constants.MAX_NULLIFIERS_PER_ADDRESS &&
            !userNullifiersState.getHasAvailableExhaustedSlot() &&
            isValidationMode
        ) {
            revert AllNullifierSlotsActive();
        }

        // === Check paymaster's deposit balance ===
        if (getDeposit() < maxCost && isValidationMode) {
            revert InsufficientPaymasterFund();
        }

        // === Check if joining fee is sufficient ===
        if (
            (JOINING_AMOUNT - nullifierGasUsage[data.proof.nullifier]) <
            maxCost &&
            isValidationMode
        ) {
            revert UserOpExceedsGasAmount();
        }

        // === Pool has members (merkleTreeSize) ===
        if (_merkleTree.size == 0 && isValidationMode) {
            revert PoolHasNoMembers();
        }
        // === Check merkleTreeDepth ===
        if (
            (data.proof.merkleTreeDepth < MIN_TREE_DEPTH ||
                data.proof.merkleTreeDepth > MAX_TREE_DEPTH)
        ) {
            revert InvalidTreeDepth();
        }

        // === Root from history ===
        uint256 expectedRoot = roots[data.config.merkleRootIndex];
        if (
            (data.proof.merkleTreeRoot != expectedRoot || expectedRoot == 0) &&
            isValidationMode
        ) {
            revert UnknownStateRoot();
        }

        // === Check proof scope ===
        if ((data.proof.scope != SCOPE) && isValidationMode) {
            revert ScopeMismatch();
        }

        // === Check proof message ===
        bytes32 messageHash = PrepaidGasLib._getMessageHash(userOp, entryPoint);
        if ((data.proof.message != uint256(messageHash)) && isValidationMode) {
            revert MessageMismatch();
        }

        if (!_validateProof(data.proof) && isValidationMode) {
            revert ProofVerificationFailed();
        }

        // === Return appropriate context ===
        if (!isValidationMode) {
            return (
                PostOpContextLib.encodeActivationContext(
                    userOpHash,
                    data.proof.nullifier,
                    userNullifiersState,
                    sender
                ),
                Constants.VALIDATION_FAILED
            );
        }

        return (
            PostOpContextLib.encodeActivationContext(
                userOpHash,
                data.proof.nullifier,
                userNullifiersState,
                sender
            ),
            _packValidationData(false, 0, 0)
        );
    }

    function _postOp(
        PostOpMode /*mode */,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) internal virtual override {
        require(context.length >= 1, "Context too short");

        PostOpContextLib.NullifierMode nullifierMode = PostOpContextLib
            .NullifierMode(uint8(context[0]));
        uint256 totalGasCost = actualGasCost;
        if (nullifierMode == PostOpContextLib.NullifierMode.ACTIVATION) {
            PostOpContextLib.ActivationContext
                memory activationContext = PostOpContextLib
                    .decodeActivationContext(context);
            uint256 postOpGasCost = Constants.POSTOP_ACTIVATION_GAS_COST *
                actualUserOpFeePerGas;
            totalGasCost += postOpGasCost;
            _handleActivationPostOp(
                totalGasCost,
                activationContext.nullifier,
                activationContext.userOpHash,
                activationContext.sender,
                activationContext.userNullifiersState
            );
            totalDeposit -= totalGasCost;
            emit UserOpSponsored(
                activationContext.sender,
                activationContext.userOpHash,
                totalGasCost
            );
        } else if (nullifierMode == PostOpContextLib.NullifierMode.CACHED) {
            PostOpContextLib.CachedContext
                memory cachedContext = PostOpContextLib.decodeCachedContext(
                    context
                );
            uint256 postOpGasCost = Constants.POSTOP_CACHE_GAS_COST *
                actualUserOpFeePerGas;
            totalGasCost += postOpGasCost;
            _handleCachedPostOp(
                totalGasCost,
                cachedContext.userOpHash,
                cachedContext.sender,
                cachedContext.userNullifiersState
            );
            totalDeposit -= totalGasCost;
            emit UserOpSponsored(
                cachedContext.sender,
                cachedContext.userOpHash,
                totalGasCost
            );
        } else {
            // should never happen
            revert("Unknown NullifierMode");
        }
    }

    /// @notice Handle activation postOp with proper state initialization
    function _handleActivationPostOp(
        uint256 totalGasCost,
        uint256 nullifier,
        bytes32 userOpHash,
        address sender,
        uint256 currentNullifiersState
    ) internal {
        // 1. Deduct gas from the new nullifier
        nullifierGasUsage[nullifier] += totalGasCost;
        uint8 currentCount = currentNullifiersState
            .getActivatedNullifierCount();
        if (currentCount == 0) {
            // First nullifier
            bytes32 nullifierSlotKey = keccak256(abi.encode(sender, 0));
            userNullifiers[nullifierSlotKey] = nullifier;
            userNullifiersStates[sender] = currentNullifiersState
                .initializeFirstNullifier();
            emit NullifierConsumed(userOpHash, nullifier, totalGasCost, 0);
            return;
        }

        bool hasExhaustedSlot = currentNullifiersState
            .getHasAvailableExhaustedSlot();

        if (hasExhaustedSlot) {
            // Reuse exhausted slot
            uint8 slotIndex = currentNullifiersState.getExhaustedSlotIndex();
            bytes32 nullifierSlotKey = keccak256(abi.encode(sender, slotIndex));
            userNullifiers[nullifierSlotKey] = nullifier;
            userNullifiersStates[sender] = currentNullifiersState
                .reuseExhaustedSlot();
            emit NullifierConsumed(
                userOpHash,
                nullifier,
                totalGasCost,
                slotIndex
            );
        } else {
            // Second nullifier (currentCount == 1)
            bytes32 nullifierSlotKey = keccak256(abi.encode(sender, 1));
            userNullifiers[nullifierSlotKey] = nullifier;
            userNullifiersStates[sender] = currentNullifiersState
                .addSecondNullifier();
            emit NullifierConsumed(userOpHash, nullifier, totalGasCost, 2);
        }
    }

    /// @notice Handle cached postOp with proper activeNullifierIndex management
    function _handleCachedPostOp(
        uint256 totalGasCost,
        bytes32 userOpHash,
        address sender,
        uint256 userNullifiersState
    ) internal {
        // Process consumption and update state
        uint256 updatedState = _processNullifierConsumption(
            sender,
            userOpHash,
            totalGasCost,
            userNullifiersState
        );

        // Update final state
        userNullifiersStates[sender] = updatedState;
    }

    /// @notice Internal function to process nullifier consumption with wraparound logic
    /// @param sender The user state key
    /// @param totalGasCost Total gas cost to consume
    /// @return updatedState The updated nullifier state flags
    function _processNullifierConsumption(
        address sender,
        bytes32 userOpHash,
        uint256 totalGasCost,
        uint256 currentUserNullifiersState
    ) internal returns (uint256 updatedState) {
        updatedState = currentUserNullifiersState;

        uint8 activatedCount = updatedState.getActivatedNullifierCount();
        uint8 startIndex = updatedState.getActiveNullifierIndex();
        uint256 remainingCost = totalGasCost;

        // Consume starting from activeNullifierIndex with wraparound
        for (uint8 i = 0; i < activatedCount && remainingCost > 0; i++) {
            uint8 currentIndex = (startIndex + i) %
                Constants.MAX_NULLIFIERS_PER_ADDRESS;
            bytes32 nullifierKey = keccak256(abi.encode(sender, currentIndex));
            uint256 nullifier = userNullifiers[nullifierKey];
            if (nullifier == 0) {
                continue; // Skip
            }

            uint256 used = nullifierGasUsage[nullifier];
            uint256 available = JOINING_AMOUNT - used;
            uint256 toConsume = remainingCost > available
                ? available
                : remainingCost;

            // Update gas usage
            nullifierGasUsage[nullifier] += toConsume;
            remainingCost = remainingCost - toConsume;
            emit NullifierConsumed(
                userOpHash,
                nullifier,
                toConsume,
                currentIndex
            );

            if (nullifierGasUsage[nullifier] >= JOINING_AMOUNT) {
                // not marking the nullifier 0, for gas savings
                // userNullifiers[nullifierSlotKey] = 0;
                updatedState = updatedState.markSlotAsExhausted(currentIndex);
            }
        }
    }

    function _pull(
        address /*_sender*/,
        uint256 _amount
    ) internal virtual override(PrepaidGasPool) {
        if (msg.value != _amount) revert InsufficientValue();
        _depositToEntryPoint(msg.value);
    }

    function getMessageHash(
        PackedUserOperation calldata userOp
    ) public view returns (bytes32) {
        return PrepaidGasLib._getMessageHash(userOp, entryPoint);
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
