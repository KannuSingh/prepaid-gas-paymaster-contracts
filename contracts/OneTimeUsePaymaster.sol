// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@account-abstraction/contracts/core/Helpers.sol";
import "@account-abstraction/contracts/core/UserOperationLib.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PaymasterValidationErrors} from "./errors/PaymasterValidationErrors.sol";
import {PoolErrors} from "./errors/PoolErrors.sol";
import {BaseErrors} from "./errors/BaseErrors.sol";
import {IPoolMembershipProofVerifier} from "./interfaces/IPoolMembershipProofVerifier.sol";
import "./base/BasePaymaster.sol";
import "./base/PrepaidGasPoolManager.sol";
import "./base/DataLib.sol";
import "./base/Constants.sol";

// import "hardhat/console.sol";

/// @title OneTimeUsePaymaster
/// @notice A paymaster that sponsors a UserOperation exactly once per unique nullifier,
/// managing user deposits in pools where the joining fee covers a single transaction.
contract OneTimeUsePaymaster is BasePaymaster, PrepaidGasPoolManager {
    using UserOperationLib for PackedUserOperation;

    /// @notice Total user deposits held by this paymaster in the EntryPoint, attributed to *unused* pool memberships.
    /// Once a nullifier is used, the corresponding joiningFee is no longer considered a "user deposit" but becomes potential revenue.
    uint256 public totalUsersDeposit;

    /// @notice Privacy verifier contract for pool membership proofs
    IPoolMembershipProofVerifier public immutable verifier;

    /// @notice Mapping to track used nullifiers.
    /// The nullifier identifies a unique one-time use instance linked to a pool membership.
    mapping(uint256 => bool) public usedNullifiers;

    // ============= Events ==============
    event UserOpSponsored(
        bytes32 indexed userOpHash,
        uint256 indexed poolId,
        address sender,
        uint256 actualGasCost,
        uint256 nullifier
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

    /// @inheritdoc IPoolManager
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
        poolId = _createPool(joiningFee);
    }

    /// @inheritdoc IPoolManager
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

    /// @inheritdoc IPoolManager
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
    /// @notice Validates a UserOperation for one-time use, ensuring its nullifier has not been used,
    /// and that the associated pool membership is valid and has sufficient joining fee.
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
        uint256 nullifier = proof.nullifier;

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
        // === 3. Validate pool existence (fundamental configuration check) ===
        if (!poolExists[poolId]) {
            revert PoolErrors.PoolDoesNotExist(poolId);
        }
        PoolConfig storage pool = pools[poolId]; // Retrieve pool configuration.

        // === From this point, checks are about the *content* or *state* that determines sponsorship.
        // Their failure will result in `VALIDATION_FAILED` (not a revert) during estimation mode,
        // allowing the bundler to proceed. In actual validation mode, these failures will revert. ===

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
        if (pool.joiningFee < requiredPreFund && isValidationMode) {
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

        // === 11. Check nullifier usage ===
        // This is the core "one-time use" logic.
        if (usedNullifiers[nullifier] && isValidationMode) {
            revert PaymasterValidationErrors.NullifierAlreadyUsed(nullifier);
        }

        // === 12. Actual ZKP verification ===
        if (!_validateProof(proof) && isValidationMode) {
            revert PaymasterValidationErrors.ProofVerificationFailed();
        }

        // === 13. Gas estimation mode or final success ===
        // If `isValidationMode` is false (estimation mode), it means all preceding
        // checks (which were executed to estimate gas) passed without an early
        // return. In this case, we return `VALIDATION_FAILED` to signal that
        // the paymaster would NOT sponsor this UserOp (due to dummy data, etc.),
        // but the gas estimation was performed.
        if (!isValidationMode) {
            return (
                abi.encode(
                    poolId,
                    proof.nullifier,
                    pool.joiningFee,
                    userOpHash,
                    sender
                ), // Dummy context for estimation
                Constants.VALIDATION_FAILED // Explicitly return failure for estimation
            );
        }

        // If `isValidationMode` is true, and we reached here, it means all
        // validation checks passed successfully for actual sponsorship.
        return (
            abi.encode(
                poolId,
                proof.nullifier,
                pool.joiningFee,
                userOpHash,
                sender
            ),
            _packValidationData(false, 0, 0) // Validation success (0)
        );
    }

    /// @inheritdoc BasePaymaster
    /// @notice Post-operation processing for OneTimeUsePaymaster.
    /// Deducts actual gas cost from the pool, and adjusts `totalUsersDeposit` to reflect
    /// that the joining fee for this nullifier is now "consumed" (moves to revenue).
    function _postOp(
        PostOpMode /*mode*/,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) internal override {
        // Decode context: poolId, nullifier, and the original joiningFee associated with this transaction.
        (
            uint256 poolId,
            uint256 nullifier,
            uint256 joiningFee,
            bytes32 userOpHash,
            address sender
        ) = abi.decode(context, (uint256, uint256, uint256, bytes32, address));
        //  Mark nullifier as used
        usedNullifiers[nullifier] = true;
        // Calculate total cost, including EntryPoint overhead.
        uint256 postOpGasCost = Constants.POSTOP_GAS_COST *
            actualUserOpFeePerGas;
        uint256 totalGasCost = actualGasCost + postOpGasCost;

        // Deduct the actual gas cost from the pool's total deposits.
        // This moves the `actualGasCost` portion from the pool's balance to EntryPoint's fee recipient.
        _reduceDeposits(poolId, totalGasCost);

        // Now, for the OneTimeUsePaymaster, the *entire* joiningFee for this nullifier
        // is considered "consumed." Any remainder after `totalGasCost` is now revenue.
        // So, we subtract the *full* joiningFee from `totalUsersDeposit`.
        // This effectively moves the remaining portion of the joiningFee into the paymaster's
        // general revenue that can be withdrawn.
        if (totalUsersDeposit < joiningFee) {
            // Should theoretically not happen if `totalUsersDeposit` is managed correctly,
            // but good for defensive programming. Could revert or just set to 0.
            totalUsersDeposit = 0;
        } else {
            totalUsersDeposit -= joiningFee;
        }

        emit UserOpSponsored(
            userOpHash,
            poolId,
            sender,
            totalGasCost,
            nullifier
        );
    }

    // ============ Public Utility Functions ============

    /// @notice Generates a dummy paymaster data stub for gas estimation purposes.
    /// @dev This data is designed to pass initial structural checks but will lead to `VALIDATION_FAILED`
    /// during `validatePaymasterUserOp` if in estimation mode, to prevent misuse.
    /// @param context The context for the paymaster (expected to be `poolId` encoded as bytes32).
    /// @return The custom paymaster data bytes suitable for gas estimation.
    function getPaymasterStubData(
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

        (uint256 latestRoot, uint32 rootIndex) = getLatestValidRootInfo(poolId);

        return DataLib.generateStubData(poolId, rootIndex, latestRoot);
    }

    // ============ Withdrawal & Revenue Management (Overrides from BasePaymaster) ============

    /// @inheritdoc BasePaymaster
    /// @notice Allows the owner to withdraw protocol revenue from the EntryPoint.
    /// @dev Revenue is calculated as total ETH in EntryPoint minus funds attributed to *unused* user prepayments.
    /// @param withdrawAddress The address to send the withdrawn funds to.
    /// @param amount The amount of revenue to withdraw.
    function withdrawTo(
        address payable withdrawAddress,
        uint256 amount
    ) external virtual override onlyOwner {
        // Calculate the current actual deposit balance of this paymaster in the EntryPoint.
        uint256 currentEntryPointDeposit = getDeposit();

        // Calculate available revenue: total funds in EntryPoint less what's reserved for *unused* users.
        uint256 revenue = currentEntryPointDeposit - totalUsersDeposit;

        // Ensure the withdrawal amount is valid and does not exceed available revenue.
        if (amount == 0 || amount > revenue) {
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
