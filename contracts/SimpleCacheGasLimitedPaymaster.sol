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
import "./base/NullifierCacheStateLib.sol";

/// @title SimpleCacheEnabledGasLimitedPaymaster
/// @notice Paymaster that uses pool membership proofs to authorize gas payments from pool deposits,
/// with a per-user gas limit tied to their joining fee and smart nullifier caching.
contract SimpleCacheEnabledGasLimitedPaymaster is
    BasePaymaster,
    PrepaidGasPoolManager
{
    using UserOperationLib for PackedUserOperation;
    using NullifierCacheStateLib for uint256;

    enum NullifierMode {
        ACTIVATION, // ZK proof transaction (first time activation)
        CACHED // Cached transaction (consuming from activated nullifiers)
    }

    /// @notice Total user deposits held by this paymaster in the EntryPoint, attributed to users.
    /// This is used to track the protocol's available revenue (totalEntryPointDeposit - totalUsersDeposit).
    uint256 public totalUsersDeposit;

    /// @notice Privacy verifier contract for pool membership proofs
    IPoolMembershipProofVerifier public immutable verifier;

    /// @notice User gas usage tracking per nullifier : nullifier => gasUsed
    mapping(uint256 => uint256) public nullifierGasUsage;

    /// @notice Cache mapping: keccak(poolId,sender) => UserNullifiers[2]
    mapping(bytes32 => uint256[2]) public userNullifiers;
    /// @notice Cache mapping: keccak(poolId,sender) => packed state flags
    mapping(bytes32 => uint256) public userNullifiersStates;

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
            Constants.SIMPLE_CACHED_PAYMASTER_DATA_SIZE
        ) {
            // Cached path - 85 bytes (paymaster + verification gas + postop gas + poolId + mode)
            return
                _validateCachedEnabledPaymasterUserOp(
                    userOp,
                    userOpHash,
                    requiredPreFund
                );
        }
        address sender = userOp.getSender();

        // === 1. Validate data structure and decode custom paymaster data using shared DataLib ===
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

        // === 2. Validate Merkle Tree Depth ===
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

        // === 3. Validate pool existence ===
        if (!poolExists[poolId]) {
            revert PoolErrors.PoolDoesNotExist(poolId);
        }
        PoolConfig storage pool = pools[poolId];

        // === State validation checks (fail gracefully in estimation mode) ===
        bytes32 userStateKey = DataLib.getUserStateKey(poolId, sender);
        uint256 userNullifiersState = userNullifiersStates[userStateKey];

        // Check if we can add new nullifier
        if (
            userNullifiersState.getActivatedNullifierCount() >=
            Constants.MAX_NULLIFIERS_PER_ADDRESS &&
            !userNullifiersState.getHasAvailableExhaustedSlot() &&
            isValidationMode
        ) {
            revert PaymasterValidationErrors.AllNullifierSlotsActive();
        }

        // === 4. Pool has members ===
        if (getMerkleTreeSize(poolId) == 0 && isValidationMode) {
            revert PoolErrors.PoolHasNoMembers();
        }

        // === 5. Merkle root index bounds ===
        if (
            data.config.merkleRootIndex >= pool.rootHistoryCount &&
            isValidationMode
        ) {
            revert PaymasterValidationErrors.InvalidMerkleRootIndex(
                data.config.merkleRootIndex,
                pool.rootHistoryCount
            );
        }

        // === 6. Check if joining fee is sufficient ===
        if (
            (pool.joiningFee - nullifierGasUsage[proof.nullifier]) <
            requiredPreFund &&
            isValidationMode
        ) {
            revert PaymasterValidationErrors.UserExceededGasFund();
        }

        // === 7. Check paymaster's overall deposit balance ===
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

        // === 11. ZKP verification ===
        if (!_validateProof(proof) && isValidationMode) {
            revert PaymasterValidationErrors.ProofVerificationFailed();
        }

        // === Return appropriate context ===
        if (!isValidationMode) {
            return (
                abi.encode(
                    NullifierMode.ACTIVATION,
                    poolId,
                    userOpHash,
                    proof.nullifier,
                    sender
                ),
                Constants.VALIDATION_FAILED
            );
        }

        return (
            abi.encode(
                NullifierMode.ACTIVATION,
                poolId,
                userOpHash,
                proof.nullifier,
                sender
            ),
            _packValidationData(false, 0, 0)
        );
    }

    function _validateCachedEnabledPaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    ) internal virtual returns (bytes memory context, uint256 validationData) {
        address sender = userOp.getSender();

        // === Extract poolId from cached data ===
        bytes memory data = userOp.paymasterAndData[52:];
        require(data.length >= 33, "Invalid packed paymaster data");

        uint256 poolId;
        uint8 mode;

        assembly {
            poolId := mload(add(data, 32))
            mode := byte(0, mload(add(data, 33)))
        }

        bool isValidationMode = mode ==
            uint8(Constants.PaymasterMode.VALIDATION);

        // === Validate pool existence ===
        if (!poolExists[poolId]) {
            revert PoolErrors.PoolDoesNotExist(poolId);
        }

        // === Get cached nullifier state ===
        bytes32 userStateKey = DataLib.getUserStateKey(poolId, sender);
        uint256 userNullifiersState = userNullifiersStates[userStateKey];
        if (
            userNullifiersState.getActivatedNullifierCount() == 0 &&
            isValidationMode
        ) {
            revert PaymasterValidationErrors.SenderNotCached(sender, poolId);
        }

        // === Check paymaster's deposit balance ===
        if (getDeposit() < requiredPreFund && isValidationMode) {
            revert PaymasterValidationErrors.InsufficientPaymasterFund();
        }

        // === Calculate total available gas using activeNullifierIndex ===
        uint256 totalAvailable = _calculateAvailableGasWithActiveIndex(
            userStateKey,
            poolId
        );

        // === Check if sufficient gas available ===
        if (totalAvailable < requiredPreFund && isValidationMode) {
            revert PaymasterValidationErrors.UserExceededGasFund();
        }

        if (!isValidationMode) {
            return (
                abi.encode(NullifierMode.CACHED, poolId, userOpHash, 0, sender),
                Constants.VALIDATION_FAILED
            );
        }

        return (
            abi.encode(NullifierMode.CACHED, poolId, userOpHash, 0, sender),
            _packValidationData(false, 0, 0)
        );
    }

    /// @notice Calculate total available gas starting from activeNullifierIndex with wraparound
    /// @param userStateKey The user's nullifier state key
    /// @param poolId The pool ID to get joining fee from
    /// @return totalAvailable Total available gas across active nullifiers
    function _calculateAvailableGasWithActiveIndex(
        bytes32 userStateKey,
        uint256 poolId
    ) internal view returns (uint256 totalAvailable) {
        uint256 joiningFee = pools[poolId].joiningFee; // Cache to avoid stack too deep
        uint256 userNullifiersState = userNullifiersStates[userStateKey];

        uint8 activatedCount = userNullifiersState.getActivatedNullifierCount();
        uint8 startIndex = userNullifiersState.getActiveNullifierIndex();

        // Calculate available gas for each active nullifier
        for (uint8 i = 0; i < activatedCount; i++) {
            totalAvailable += _calculateSlotAvailableGas(
                userStateKey,
                (startIndex + i) % 2,
                joiningFee
            );
        }
    }

    /// @notice Calculate available gas for a specific nullifier slot
    /// @param userStateKey The user's nullifier state key
    /// @param slotIndex The slot index to check
    /// @param joiningFee The pool's joining fee
    /// @return available Available gas for this slot
    function _calculateSlotAvailableGas(
        bytes32 userStateKey,
        uint8 slotIndex,
        uint256 joiningFee
    ) internal view returns (uint256 available) {
        uint256 nullifier = userNullifiers[userStateKey][slotIndex];

        if (nullifier == 0) {
            return 0; // Empty slot
        }

        uint256 used = nullifierGasUsage[nullifier];
        available = joiningFee > used ? joiningFee - used : 0;
    }

    /// @inheritdoc BasePaymaster
    /// @notice Post-operation processing: Deduct gas costs from the user's allowance and pool deposits.
    function _postOp(
        PostOpMode /*mode*/,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) internal override {
        (
            NullifierMode mode,
            uint256 poolId,
            bytes32 userOpHash,
            uint256 nullifierOrNullifierIndices,
            address sender
        ) = abi.decode(
                context,
                (NullifierMode, uint256, bytes32, uint256, address)
            );

        if (mode == NullifierMode.ACTIVATION) {
            uint256 postOpGasCost = Constants.POSTOP_ACTIVATION_GAS_COST *
                actualUserOpFeePerGas;
            uint256 totalGasCost = actualGasCost + postOpGasCost;
            _handleActivationPostOp(
                poolId,
                nullifierOrNullifierIndices,
                totalGasCost,
                userOpHash,
                sender
            );
            _reduceDeposits(poolId, totalGasCost);
            totalUsersDeposit -= totalGasCost;
        } else {
            uint256 postOpGasCost = Constants.POSTOP_CACHE_GAS_COST *
                actualUserOpFeePerGas;
            uint256 totalGasCost = actualGasCost + postOpGasCost;
            _handleCachedPostOp(poolId, totalGasCost, userOpHash, sender);
            _reduceDeposits(poolId, totalGasCost);
            totalUsersDeposit -= totalGasCost;
        }
    }

    /// @notice Handle cached postOp with proper activeNullifierIndex management
    function _handleCachedPostOp(
        uint256 poolId,
        uint256 totalGasCost,
        bytes32 userOpHash,
        address sender
    ) internal {
        bytes32 userStateKey = DataLib.getUserStateKey(poolId, sender);
        uint256 joiningFee = pools[poolId].joiningFee; // Cache to avoid stack too deep

        // Process consumption and update state
        uint256 updatedState = _processNullifierConsumption(
            userStateKey,
            totalGasCost,
            joiningFee
        );

        // Update final state
        userNullifiersStates[userStateKey] = updatedState;
        emit UserOpSponsoredCached(userOpHash, poolId, sender, totalGasCost, 0);
    }

    /// @notice Internal function to process nullifier consumption with wraparound logic
    /// @param userStateKey The user state key
    /// @param totalGasCost Total gas cost to consume
    /// @param joiningFee The pool's joining fee
    /// @return updatedState The updated nullifier state flags
    function _processNullifierConsumption(
        bytes32 userStateKey,
        uint256 totalGasCost,
        uint256 joiningFee
    ) internal returns (uint256 updatedState) {
        updatedState = userNullifiersStates[userStateKey];
        uint256[2] storage _userNullifiers = userNullifiers[userStateKey];

        uint8 activatedCount = updatedState.getActivatedNullifierCount();
        uint8 startIndex = updatedState.getActiveNullifierIndex();
        uint256 remainingCost = totalGasCost;

        // Consume starting from activeNullifierIndex with wraparound
        for (uint8 i = 0; i < activatedCount && remainingCost > 0; i++) {
            uint8 currentIndex = (startIndex + i) % 2;
            bool wasExhausted;

            (remainingCost, wasExhausted) = _consumeFromNullifierSlot(
                _userNullifiers,
                currentIndex,
                remainingCost,
                joiningFee
            );

            // Update state if slot was exhausted
            if (wasExhausted) {
                updatedState = updatedState.markSlotAsExhausted(currentIndex);
            }
        }
    }

    /// @notice Consume gas from a specific nullifier slot
    /// @param _userNullifiers Storage reference to user nullifiers array
    /// @param slotIndex The slot index to consume from
    /// @param remainingCost Remaining gas cost to consume
    /// @param joiningFee The pool's joining fee
    /// @return newRemainingCost Updated remaining cost after consumption
    /// @return wasExhausted Whether the slot was exhausted and cleared
    function _consumeFromNullifierSlot(
        uint256[2] storage _userNullifiers,
        uint8 slotIndex,
        uint256 remainingCost,
        uint256 joiningFee
    ) internal returns (uint256 newRemainingCost, bool wasExhausted) {
        uint256 nullifier = _userNullifiers[slotIndex];

        if (nullifier == 0) {
            return (remainingCost, false); // Skip empty slots
        }

        uint256 used = nullifierGasUsage[nullifier];
        uint256 available = joiningFee - used;
        uint256 toConsume = remainingCost > available
            ? available
            : remainingCost;

        // Update gas usage
        nullifierGasUsage[nullifier] += toConsume;
        newRemainingCost = remainingCost - toConsume;

        // Check if slot is now exhausted
        if (nullifierGasUsage[nullifier] >= joiningFee) {
            _userNullifiers[slotIndex] = 0;
            wasExhausted = true;
        }
    }

    /// @notice Handle activation postOp with proper state initialization
    function _handleActivationPostOp(
        uint256 poolId,
        uint256 nullifier,
        uint256 totalGasCost,
        bytes32 userOpHash,
        address sender
    ) internal {
        // 1. Deduct gas from the new nullifier
        nullifierGasUsage[nullifier] += totalGasCost;

        // 2. Add nullifier to user's activated list
        bytes32 userStateKey = DataLib.getUserStateKey(poolId, sender);
        uint256 userNullifiersState = userNullifiersStates[userStateKey];
        uint256[2] storage _userNullifiers = userNullifiers[userStateKey];

        uint8 currentCount = userNullifiersState.getActivatedNullifierCount();
        bool hasExhaustedSlot = userNullifiersState
            .getHasAvailableExhaustedSlot();

        if (hasExhaustedSlot) {
            // Reuse exhausted slot
            uint8 slotIndex = userNullifiersState.getExhaustedSlotIndex();
            _userNullifiers[slotIndex] = nullifier;
            userNullifiersState = userNullifiersState.reuseExhaustedSlot();
        } else if (currentCount == 0) {
            // First nullifier
            _userNullifiers[0] = nullifier;
            userNullifiersState = userNullifiersState.initializeFirstNullifier();
        } else {
            // Second nullifier (currentCount == 1)
            _userNullifiers[1] = nullifier;
            userNullifiersState = userNullifiersState.addSecondNullifier();
        }

        userNullifiersStates[userStateKey] = userNullifiersState;
        emit UserOpSponsoredActivation(
            userOpHash,
            poolId,
            sender,
            totalGasCost,
            nullifier
        );
    }

    /// @notice Generates paymaster data stub for gas estimation purposes.
    function getPaymasterStubData(
        PackedUserOperation calldata userOp,
        bytes calldata context
    ) public view returns (bytes memory) {
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
        bytes32 userStateKey = DataLib.getUserStateKey(poolId, sender);
        uint256 userNullifiersState = userNullifiersStates[userStateKey];
        uint8 activatedCount = userNullifiersState.getActivatedNullifierCount();

        if (activatedCount > 0) {
            // Return cached stub data (33 bytes custom data = 85 bytes total)
            return
                abi.encodePacked(
                    poolId,
                    uint8(Constants.PaymasterMode.ESTIMATION)
                );
        } else {
            // Return full ZK proof stub data (480 bytes custom data = 532 bytes total)
            (uint256 latestRoot, uint32 rootIndex) = getLatestValidRootInfo(
                poolId
            );
            return DataLib.generateStubData(poolId, rootIndex, latestRoot);
        }
    }

    // ============ Withdrawal & Revenue Management ============

    /// @inheritdoc BasePaymaster
    function withdrawTo(
        address payable withdrawAddress,
        uint256 amount
    ) external virtual override onlyOwner {
        uint256 currentEntryPointDeposit = getDeposit();
        uint256 revenue = currentEntryPointDeposit - totalUsersDeposit;

        if (amount == 0 || amount > revenue) {
            revert BaseErrors.WithdrawalNotAllowed();
        }

        entryPoint.withdrawTo(withdrawAddress, amount);
        emit RevenueWithdrawn(withdrawAddress, amount);
    }

    function getRevenue() public view returns (uint256) {
        uint256 currentEntryPointDeposit = getDeposit();
        uint256 revenue = currentEntryPointDeposit - totalUsersDeposit;
        return revenue;
    }

    function getMessageHash(
        PackedUserOperation calldata userOp
    ) public view returns (bytes32) {
        return DataLib._getMessageHash(userOp, entryPoint);
    }
}
