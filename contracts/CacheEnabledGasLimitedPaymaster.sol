// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@account-abstraction/contracts/core/Helpers.sol";
import "@account-abstraction/contracts/core/UserOperationLib.sol";
import {PaymasterValidationErrors} from "./errors/PaymasterValidationErrors.sol";
import {PoolErrors} from "./errors/PoolErrors.sol";
import {BaseErrors} from "./errors/BaseErrors.sol";
import {IPoolMembershipProofVerifier} from "./interfaces/IPoolMembershipProofVerifier.sol";
import {PrepaidGasPoolManager} from "./base/PrepaidGasPoolManager.sol";
import "./base/BasePaymaster.sol";
import "./base/Constants.sol";
import "./base/DataLib.sol";

// import "hardhat/console.sol";

/// @title CacheEnabledGasLimitedPaymaster
/// @notice Paymaster that uses pool membership proofs to authorize gas payments from pool deposits,
/// with a per-user gas limit tied to their joining fee.
contract CacheEnabledGasLimitedPaymaster is
    BasePaymaster,
    PrepaidGasPoolManager
{
    using UserOperationLib for PackedUserOperation;

    /// @notice User's nullifier management state
    struct UserNullifierState {
        uint256[8] nullifiers; // Fixed array of activated nullifiers
        uint8 count; // Active nullifiers count (with remaining balance)
        uint8 exhaustedSlotIndex; // Last exhausted slot index (available for reuse)
        bool hasAvailableExhaustedSlot; // Whether we have an exhausted slot available for reuse
    }

    enum NullifierMode {
        ACTIVATION, // ZK proof transaction (first time activation)
        CACHED // Cached transaction (consuming from activated nullifiers)
    }

    /// @notice Total user deposits held by this paymaster in the EntryPoint, attributed to users.
    /// This is used to track the protocol's available revenue (totalEntryPointDeposit - totalUsersDeposit).
    uint256 public totalUsersDeposit;

    /// @notice Privacy verifier contract for pool membership proofs
    IPoolMembershipProofVerifier public immutable verifier;

    /// @notice User gas usage tracking per nullifier
    mapping(uint256 => uint256) public poolMembersGasData;

    /// @notice Cache mapping: poolId => sender => nullifier(0 = not cached)
    mapping(uint256 => mapping(address => uint256)) public cachedSenders;

    /// @notice Cache mapping: poolId => sender => UserNullifierState
    mapping(uint256 => mapping(address => UserNullifierState))
        public userStates;

    // ============= Events ==============

    event UserOpSponsoredActivation(
        bytes32 indexed userOpHash,
        uint256 indexed poolId,
        address sender,
        uint256 actualGasCost,
        uint256 nullifier
    );
    event UserOpSponsoredCached(
        bytes32 indexed userOpHash,
        uint256 indexed poolId,
        address sender,
        uint256 actualGasCost,
        uint256 nullifierIndices
    );

    event RevenueWithdrawn(address indexed recipient, uint256 amount);

    // ============ Constructor ============
    constructor(
        address _entryPoint,
        address _verifier
    ) BasePaymaster(IEntryPoint(_entryPoint)) {
        if (_verifier == address(0)) {
            revert BaseErrors.InvalidVerifierAddress();
        }
        verifier = IPoolMembershipProofVerifier(_verifier);
    }

    // ============ Overrides from PrepaidGasPoolManager (Concrete Implementations) ============

    /// @inheritdoc PrepaidGasPoolManager
    /// @notice Creates a new prepaid gas pool with specified joining fee.
    /// @dev This implementation adds owner-only access control.
    function createPool(
        uint256 joiningFee
    )
        external
        override
        onlyOwner
        onlyValidJoiningFee(joiningFee)
        returns (uint256 poolId)
    {
        // Call the internal helper from PrepaidGasPoolManager to create the pool
        poolId = _createPool(joiningFee);
    }

    /// @inheritdoc PrepaidGasPoolManager
    /// @notice Adds a single member to a pool.
    /// @dev This implementation handles the deposit to the EntryPoint and updates internal trackers.
    function addMember(
        uint256 poolId,
        uint256 identityCommitment
    )
        external
        payable
        override
        onlyExistingPool(poolId)
        onlyCorrectJoiningFee(poolId)
        returns (uint256 merkleTreeRoot)
    {
        // 1. Deposit the received funds to the EntryPoint (internal to BasePaymaster)
        _depositToEntryPoint(msg.value);

        // 2. Update the pool's total deposits (internal to PrepaidGasPoolManager)
        _addDeposits(poolId, msg.value);

        // 3. Update this paymaster's global tracker for user deposits
        totalUsersDeposit += msg.value;

        // 4. Update Merkle tree with the new member (internal to PrepaidGasPoolManager)
        merkleTreeRoot = _addMember(poolId, identityCommitment);
    }

    /// @inheritdoc PrepaidGasPoolManager
    /// @notice Adds multiple members to a pool.
    /// @dev This implementation handles the deposit to the EntryPoint and updates internal trackers.
    function addMembers(
        uint256 poolId,
        uint256[] calldata identityCommitments
    )
        external
        payable
        override
        onlyExistingPool(poolId)
        onlyCorrectTotalJoiningFee(poolId, identityCommitments.length)
        returns (uint256 merkleTreeRoot)
    {
        // 1. Deposit the received funds to the EntryPoint (internal to BasePaymaster)
        _depositToEntryPoint(msg.value);

        // 2. Update the pool's total deposits (internal to PrepaidGasPoolManager)
        _addDeposits(poolId, msg.value);

        // 3. Update this paymaster's global tracker for user deposits
        totalUsersDeposit += msg.value;

        // 4. Update Merkle tree with new members (internal to PrepaidGasPoolManager)
        merkleTreeRoot = _addMembers(poolId, identityCommitments);
    }

    // ============ Proof Verification ============

    /// @notice Verify a pool membership proof (public view for external tooling or debugging).
    /// @param proof The pool membership proof data.
    /// @return True if the proof is valid, false otherwise.
    function verifyProof(
        DataLib.PoolMembershipProof calldata proof
    ) public view returns (bool) {
        return _validateProof(proof);
    }

    /// @notice Internal proof validation logic using the external verifier contract.
    /// @param proof The pool membership proof data.
    /// @return True if the proof is valid, false otherwise.
    function _validateProof(
        DataLib.PoolMembershipProof memory proof
    ) internal view returns (bool) {
        // Call the external verifier contract to verify the proof.
        return
            verifier.verifyProof(
                [proof.points[0], proof.points[1]],
                [
                    [proof.points[2], proof.points[3]],
                    [proof.points[4], proof.points[5]]
                ],
                [proof.points[6], proof.points[7]],
                [
                    proof.merkleTreeRoot,
                    proof.nullifier,
                    DataLib._hash(proof.message),
                    DataLib._hash(proof.scope)
                ],
                proof.merkleTreeDepth
            );
    }

    // ============ Core Paymaster Logic (Overrides from BasePaymaster) ============

    /// @inheritdoc BasePaymaster
    /// @notice Validates a UserOperation for gas payment using pool membership proof.
    /// @dev This function differentiates between validation mode (for actual execution)
    /// and estimation mode (for gas estimation).
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    )
        internal
        virtual
        override
        returns (bytes memory context, uint256 validationData)
    {
        if (
            userOp.paymasterAndData.length ==
            Constants.CACHED_PAYMASTER_DATA_SIZE
        ) {
            // Cached path - 87 bytes (paymaster + verification gas + postop gas + poolId + mode + startIndex(nullifier) + endIndex(nullifier))
            return
                _validateCachedEnabledPaymasterUserOp(
                    userOp,
                    userOpHash,
                    requiredPreFund
                );
        }
        address sender = userOp.getSender();

        // === 1. Validate data structure and decode custom paymaster data using shared DataLib ===
        // If the data format is incorrect, it's a fundamental error.
        if (!DataLib.validatePaymasterAndData(userOp.paymasterAndData)) {
            revert PaymasterValidationErrors.InvalidPaymasterData();
        }

        DataLib.PaymasterData memory data = DataLib.decodePaymasterData(
            userOp.paymasterAndData
        );

        bool isValidationMode = data.config.mode ==
            Constants.PaymasterMode.VALIDATION;
        uint256 poolId = data.poolId;
        DataLib.PoolMembershipProof memory proof = data.proof;

        // === 2. Validate Merkle Tree Depth (fundamental structural check for proof) ===
        if (
            proof.merkleTreeDepth < Constants.MIN_DEPTH ||
            proof.merkleTreeDepth > Constants.MAX_DEPTH
        ) {
            revert PaymasterValidationErrors.MerkleTreeDepthUnsupported(
                proof.merkleTreeDepth,
                Constants.MIN_DEPTH,
                Constants.MAX_DEPTH
            );
        }
        // === 3. Validate pool existence  ===
        if (!poolExists[poolId]) {
            revert PoolErrors.PoolDoesNotExist(poolId);
        }
        PoolConfig storage pool = pools[poolId]; // Retrieve pool configuration.

        // === From this point, checks are about the *content* or *state* that determines sponsorship.
        // Their failure will result in `VALIDATION_FAILED` (not a revert) during estimation mode,
        // allowing the bundler to proceed. In actual validation mode, these failures will revert. ===

        UserNullifierState storage userState = userStates[poolId][sender];
        // Only reject if array is full AND no exhausted slots available for reuse
        if (
            userState.count >= Constants.MAX_NULLIFIERS_PER_ADDRESS &&
            !userState.hasAvailableExhaustedSlot &&
            isValidationMode
        ) {
            revert PaymasterValidationErrors.AllNullifierSlotsActive();
        }

        // === 4. pool has members.
        if (getMerkleTreeSize(poolId) == 0 && isValidationMode) {
            revert PoolErrors.PoolHasNoMembers();
        }

        //  === 5. Merkle root index bounds
        if (
            data.config.merkleRootIndex >= pool.rootHistoryCount &&
            isValidationMode
        ) {
            revert PaymasterValidationErrors.InvalidMerkleRootIndex(
                data.config.merkleRootIndex,
                pool.rootHistoryCount
            );
        }

        // === 6. Check if joining fee is sufficient for the transaction ===
        if (
            (pool.joiningFee - poolMembersGasData[proof.nullifier]) <
            requiredPreFund &&
            isValidationMode
        ) {
            revert PaymasterValidationErrors.UserExceededGasFund();
        }

        // === 7. Check paymaster's overall deposit balance in EntryPoint ===
        if (getDeposit() < requiredPreFund && isValidationMode) {
            revert PaymasterValidationErrors.InsufficientPaymasterFund();
        }

        // === 8. Check proof scope ===
        if ((proof.scope != poolId) && isValidationMode) {
            revert PaymasterValidationErrors.InvalidProofScope(
                proof.scope,
                poolId
            );
        }
        // === 9. Check proof message ===
        bytes32 messageHash = DataLib._getMessageHash(userOp, entryPoint);
        if ((proof.message != uint256(messageHash)) && isValidationMode) {
            revert PaymasterValidationErrors.InvalidProofMessage(
                proof.message,
                uint256(messageHash)
            );
        }

        // === 10. Root from history ===
        uint256 expectedRoot = pool.rootsHistory[data.config.merkleRootIndex];
        if (
            (proof.merkleTreeRoot != expectedRoot || expectedRoot == 0) &&
            isValidationMode
        ) {
            revert PaymasterValidationErrors.InvalidMerkleTreeRoot(
                proof.merkleTreeRoot,
                expectedRoot
            );
        }

        // === 11. Actual ZKP verification ===
        if (!_validateProof(proof) && isValidationMode) {
            revert PaymasterValidationErrors.ProofVerificationFailed();
        }

        // === Gas estimation mode or final success ===
        // If `isValidationMode` is false (estimation mode), it means all preceding
        // checks (which were executed to estimate gas) passed without an early
        // return. In this case, we return `VALIDATION_FAILED` to signal that
        // the paymaster would NOT sponsor this UserOp (due to dummy data, etc.),
        // but the gas estimation was performed.
        if (!isValidationMode) {
            return (
                abi.encode(
                    NullifierMode.ACTIVATION,
                    poolId,
                    userOpHash,
                    proof.nullifier,
                    sender
                ), // Dummy context for estimation
                Constants.VALIDATION_FAILED // Explicitly return failure for estimation
            );
        }

        // If `isValidationMode` is true, and we reached here, it means all
        // validation checks passed successfully for actual sponsorship.
        return (
            abi.encode(
                NullifierMode.ACTIVATION,
                poolId,
                userOpHash,
                proof.nullifier,
                sender
            ), // Actual context to be passed to _postOp
            _packValidationData(false, 0, 0) // Validation success (0)
        );
    }

    function _validateCachedEnabledPaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    ) internal virtual returns (bytes memory context, uint256 validationData) {
        address sender = userOp.getSender();

        // === 2. Extract poolId from cached data (just poolId, no ZK proof) ===
        // Decode cached paymaster data: poolId + mode + startIndex + endIndex
        (
            uint256 poolId,
            Constants.PaymasterMode mode,
            uint8 startIndex,
            uint8 endIndex
        ) = abi.decode(
                userOp.paymasterAndData[52:],
                (uint256, Constants.PaymasterMode, uint8, uint8)
            );

        bool isValidationMode = mode == Constants.PaymasterMode.VALIDATION;
        // === 3. Validate pool existence ===
        if (!poolExists[poolId]) {
            revert PoolErrors.PoolDoesNotExist(poolId);
        }
        // === 4. Get cached nullifier for this sender in this pool ===
        UserNullifierState storage userState = userStates[poolId][sender];
        if (userState.count == 0 && isValidationMode) {
            revert PaymasterValidationErrors.SenderNotCached(sender, poolId);
        }

        // === 5. Validate range bounds ===
        if (
            (startIndex >= Constants.MAX_NULLIFIERS_PER_ADDRESS ||
                endIndex >= Constants.MAX_NULLIFIERS_PER_ADDRESS) &&
            isValidationMode
        ) {
            revert PaymasterValidationErrors.InvalidNullifierIndexRange(
                startIndex,
                endIndex
            );
        }
        // === 6. Check paymaster's overall deposit balance in EntryPoint ===
        if (getDeposit() < requiredPreFund && isValidationMode) {
            revert PaymasterValidationErrors.InsufficientPaymasterFund();
        }

        // === 7. Calculate total available gas in the specified range ===
        uint256 totalAvailable = 0;
        PoolConfig storage pool = pools[poolId];

        // Handle round-robin wrapping correctly
        uint8 currentIndex = startIndex;
        do {
            uint256 nullifier = userState.nullifiers[currentIndex];
            // CRITICAL: Skip empty/invalid nullifiers (attack protection)
            if (nullifier == 0) {
                currentIndex =
                    (currentIndex + 1) %
                    Constants.MAX_NULLIFIERS_PER_ADDRESS;
                continue;
            }
            uint256 used = poolMembersGasData[nullifier];
            uint256 available = pool.joiningFee > used
                ? pool.joiningFee - used
                : 0;
            totalAvailable += available;

            // Move to next index with wrapping
            currentIndex =
                (currentIndex + 1) %
                Constants.MAX_NULLIFIERS_PER_ADDRESS;
        } while (
            currentIndex !=
                (endIndex + 1) % Constants.MAX_NULLIFIERS_PER_ADDRESS
        );

        // === 8. Check if sufficient gas available ===
        if (totalAvailable < requiredPreFund && isValidationMode) {
            revert PaymasterValidationErrors.UserExceededGasFund();
        }
        bytes32 packedIndices = bytes32(
            DataLib.packIndices(startIndex, endIndex)
        );

        if (!isValidationMode) {
            return (
                abi.encode(
                    NullifierMode.CACHED,
                    poolId,
                    userOpHash,
                    packedIndices,
                    sender
                ),
                Constants.VALIDATION_FAILED // For estimation mode
            );
        }

        // === 7. Return validation success ===
        return (
            abi.encode(
                NullifierMode.CACHED,
                poolId,
                userOpHash,
                packedIndices,
                sender
            ),
            _packValidationData(false, 0, 0)
        );
    }

    /// @inheritdoc BasePaymaster
    /// @notice Post-operation processing: Deduct gas costs from the user's allowance and pool deposits.
    /// @dev This function is called by the EntryPoint after the UserOp's execution.
    function _postOp(
        PostOpMode /*mode*/, // The mode (e.g., Succeeded, Reverted) is not directly used for deductions here.
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) internal override {
        // Decode the poolId, nullifier, userOpHash, sender from the context passed during validation.
        (
            NullifierMode mode,
            uint256 poolId,
            bytes32 userOpHash,
            uint256 nullifierOrNullifierIndices, // actually bytes32 encoded, safe to decode as uint256
            address sender
        ) = abi.decode(
                context,
                (NullifierMode, uint256, bytes32, uint256, address)
            );

        // Calculate the total gas cost, including the EntryPoint's postOp overhead.
        uint256 postOpGasCost = Constants.POSTOP_GAS_COST *
            actualUserOpFeePerGas;
        uint256 totalGasCost = actualGasCost + postOpGasCost;

        // 3. Handle based on nullifier mode
        if (mode == NullifierMode.ACTIVATION) {
            _handleActivationPostOp(
                poolId,
                nullifierOrNullifierIndices,
                totalGasCost,
                userOpHash,
                sender
            );
        } else {
            _handleCachedPostOp(
                poolId,
                nullifierOrNullifierIndices,
                totalGasCost,
                userOpHash,
                sender
            );
        }

        // Deduct the gas cost from the pool's total deposits.
        _reduceDeposits(poolId, totalGasCost); // This function (from PrepaidGasPoolManager) also emits PoolDepositsReduced.

        // Deduct from the global tracker of user deposits for revenue calculation.
        totalUsersDeposit -= totalGasCost;
    }

    /// @notice Handle cached postOp (cached transaction)
    /// @dev Sequential consumption with automatic cleanup of exhausted nullifiers
    /// @param poolId The pool ID
    /// @param nullifierIndices nullifierIndices
    /// @param totalGasCost The total gas cost to deduct
    /// @param userOpHash The user operation hash
    /// @param sender The sender address
    function _handleCachedPostOp(
        uint256 poolId,
        uint256 nullifierIndices,
        uint256 totalGasCost,
        bytes32 userOpHash,
        address sender
    ) internal {
        // Unpack indices from bytes32
        (uint8 startIndex, uint8 endIndex) = DataLib.unpackIndices(
            nullifierIndices
        );

        UserNullifierState storage userState = userStates[poolId][sender];
        uint256 remainingCost = totalGasCost;

        // Consume gas sequentially with round-robin wrapping
        uint8 currentIndex = startIndex;
        do {
            // Add early exit check at the start of each iteration
            if (remainingCost == 0) break;

            uint256 nullifier = userState.nullifiers[currentIndex];
            // Add this check:
            if (nullifier == 0) {
                currentIndex =
                    (currentIndex + 1) %
                    Constants.MAX_NULLIFIERS_PER_ADDRESS;
                continue;
            }

            uint256 used = poolMembersGasData[nullifier];
            uint256 available = pools[poolId].joiningFee - used;
            uint256 toConsume = remainingCost > available
                ? available
                : remainingCost;

            // Deduct gas from this nullifier
            poolMembersGasData[nullifier] += toConsume;
            remainingCost -= toConsume;

            // Check if this nullifier is now exhausted
            if (poolMembersGasData[nullifier] >= pools[poolId].joiningFee) {
                userState.count--; // Decrement active count
                userState.exhaustedSlotIndex = currentIndex; // Mark as available for reuse
                userState.hasAvailableExhaustedSlot = true; // Set flag
            }

            // Move to next index with wrapping
            currentIndex =
                (currentIndex + 1) %
                Constants.MAX_NULLIFIERS_PER_ADDRESS;
        } while (
            currentIndex !=
                (endIndex + 1) % Constants.MAX_NULLIFIERS_PER_ADDRESS &&
                remainingCost > 0
        );

        emit UserOpSponsoredCached(
            userOpHash,
            poolId,
            sender,
            totalGasCost,
            nullifierIndices
        );
    }

    /// @notice Handle activation postOp (ZK proof transaction)
    /// @dev Simple append since validation ensures we have space
    /// @param poolId The pool ID
    /// @param nullifier The nullifier being activated
    /// @param totalGasCost The total gas cost to deduct
    /// @param userOpHash The user operation hash
    /// @param sender The sender address
    function _handleActivationPostOp(
        uint256 poolId,
        uint256 nullifier,
        uint256 totalGasCost,
        bytes32 userOpHash,
        address sender
    ) internal {
        // 1. Deduct gas from the new nullifier
        poolMembersGasData[nullifier] += totalGasCost;

        // 2. Add nullifier to user's activated list
        UserNullifierState storage userState = userStates[poolId][sender];

        if (userState.hasAvailableExhaustedSlot) {
            // Reuse exhausted slot
            userState.nullifiers[userState.exhaustedSlotIndex] = nullifier;
            userState.hasAvailableExhaustedSlot = false; // Mark as used
        } else {
            // Add to next available position (count < MAX_NULLIFIERS guaranteed by validation)
            userState.nullifiers[userState.count] = nullifier;
        }
        userState.count++;

        emit UserOpSponsoredActivation(
            userOpHash,
            poolId,
            sender,
            totalGasCost,
            nullifier
        );
    }

    /// @notice Generates paymaster data stub for gas estimation purposes.
    /// @dev Returns cached stub data (87 bytes) if sender is cached, otherwise ZK proof stub data (532 bytes)
    /// @param userOp The UserOperation for gas estimation
    /// @param context The context for the paymaster (expected to be `poolId` encoded as bytes32).
    /// @return The custom paymaster data bytes suitable for gas estimation.
    function getPaymasterStubData(
        PackedUserOperation calldata userOp,
        bytes calldata context
    ) public view returns (bytes memory) {
        // Validate the context length to ensure it's a valid uint256-encoded poolId
        if (context.length != 32) {
            revert PaymasterValidationErrors.InvalidStubContextLength(
                context.length
            );
        }

        uint256 poolId = abi.decode(context, (uint256));

        if (!poolExists[poolId]) {
            revert PoolErrors.PoolDoesNotExist(poolId);
        }

        address sender = userOp.getSender();

        // Check if sender has any activated nullifiers (cached)
        UserNullifierState storage userState = userStates[poolId][sender];
        if (userState.count > 0) {
            // Return cached stub data (35 bytes custom data = 87 bytes total)
            return DataLib.generateCachedStubData(poolId);
        } else {
            // Return full ZK proof stub data (480 bytes custom data = 532 bytes total)
            (uint256 latestRoot, uint32 rootIndex) = getLatestValidRootInfo(
                poolId
            );
            return DataLib.generateStubData(poolId, rootIndex, latestRoot);
        }
    }

    // ============ Withdrawal & Revenue Management (Overrides from BasePaymaster) ============

    /// @inheritdoc BasePaymaster
    /// @notice Allows the owner to withdraw protocol revenue from the EntryPoint.
    /// @dev Revenue is calculated as total ETH in EntryPoint minus funds attributed to active user prepayments.
    /// @param withdrawAddress The address to send the withdrawn funds to.
    /// @param amount The amount of revenue to withdraw.
    function withdrawTo(
        address payable withdrawAddress,
        uint256 amount
    ) external virtual override onlyOwner {
        // Calculate the current actual deposit balance of this paymaster in the EntryPoint.
        uint256 currentEntryPointDeposit = getDeposit();

        // Calculate available revenue: total funds in EntryPoint less what's reserved for users.
        uint256 revenue = currentEntryPointDeposit - totalUsersDeposit;

        // Ensure the withdrawal amount is valid and does not exceed available revenue.
        if (amount == 0 || amount > revenue) {
            // Using BasePaymaster__WithdrawalNotAllowed to indicate the withdrawal constraint.
            revert BaseErrors.WithdrawalNotAllowed();
        }

        // Execute the withdrawal from the EntryPoint.
        entryPoint.withdrawTo(withdrawAddress, amount);
        emit RevenueWithdrawn(withdrawAddress, amount);
    }

    function getRevenue() public view returns (uint256) {
        // Calculate the current actual deposit balance of this paymaster in the EntryPoint.
        uint256 currentEntryPointDeposit = getDeposit();

        // Calculate available revenue: total funds in EntryPoint less what's reserved for users.
        uint256 revenue = currentEntryPointDeposit - totalUsersDeposit;

        return revenue;
    }

    function getMessageHash(
        PackedUserOperation calldata userOp
    ) public view returns (bytes32) {
        return DataLib._getMessageHash(userOp, entryPoint);
    }
}
