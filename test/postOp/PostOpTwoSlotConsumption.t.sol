// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PostOpSetupBase.t.sol";
import "../mocks/MockContracts.sol";

/// @title PostOpTwoSlotConsumption Tests
/// @notice Test the core two-slot nullifier consumption logic in postOp
contract PostOpTwoSlotConsumptionTest is PostOpSetupBase {
    using NullifierCacheStateLib for uint256;

    /// @dev Test normal consumption when both slots are active (starting from slot 0)
    function test_TwoSlotConsumption_NormalFromSlot0() public {
        uint256 poolId = poolId1;
        address sender = sender1;

        console.log("=== Two-Slot Consumption: Normal from Slot 0 ===");

        // Setup: Activate two nullifiers (slot 0 and slot 1)
        _activateTwoNullifiers(poolId, sender, 0, 1);

        // Verify initial state
        uint256 state = paymaster.userNullifiersStates(
            getUserStateKey(sender, poolId)
        );
        assertEq(
            state.getActivatedNullifierCount(),
            2,
            "Should have 2 active nullifiers"
        );
        assertEq(
            state.getActiveNullifierIndex(),
            0,
            "Should start from slot 0"
        );

        // Log before consumption
        _logSlotStates(poolId, 0, 1, "BEFORE normal consumption");

        // Get initial values for assertions
        uint256 nullifier0 = getNullifier(0);
        uint256 nullifier1 = getNullifier(1);
        uint256 initialUsage0 = paymaster.nullifierGasUsage(nullifier0);
        uint256 initialUsage1 = paymaster.nullifierGasUsage(nullifier1);

        // Execute consumption (moderate amount that fits in slot 0)
        _executeCachedConsumption(poolId, sender, 100000, 2);

        // Log after consumption
        _logSlotStates(poolId, 0, 1, "AFTER normal consumption");

        // Verify consumption occurred in slot 0 first
        uint256 finalUsage0 = paymaster.nullifierGasUsage(nullifier0);
        uint256 finalUsage1 = paymaster.nullifierGasUsage(nullifier1);

        assertGt(
            finalUsage0,
            initialUsage0,
            "Slot 0 should have increased usage"
        );
        assertEq(finalUsage1, initialUsage1, "Slot 1 should be unchanged");

        console.log("Normal consumption from slot 0 successful");
    }

    /// @dev Test consumption that spills over from slot 0 to slot 1 (within user budget)
    function test_TwoSlotConsumption_CrossSlotSpillover() public {
        uint256 poolId = poolId2;
        address sender = sender2;

        console.log("=== Two-Slot Consumption: Cross-Slot Spillover ===");

        // Setup: Activate two nullifiers
        _activateTwoNullifiers(poolId, sender, 2, 3);

        uint256 joiningFee = paymaster.getJoiningFee(poolId);
        uint256 nullifier0 = getNullifier(2);
        uint256 nullifier1 = getNullifier(3);

        // Get available gas in slot 0
        uint256 initialUsage0 = paymaster.nullifierGasUsage(nullifier0);
        uint256 availableInSlot0 = joiningFee - initialUsage0;
        uint256 initialUsage1 = paymaster.nullifierGasUsage(nullifier1);

        // Calculate safe spillover amount (ensures we don't exceed user's total budget)
        uint256 totalUserBudget = joiningFee * 2; // User has 2 nullifiers
        uint256 totalCurrentUsage = initialUsage0 + initialUsage1;
        uint256 totalAvailable = totalUserBudget - totalCurrentUsage;

        // Consume slightly more than slot 0 has, but within total budget
        uint256 spilloverAmount = availableInSlot0 + 20000; // 20k spillover
        if (spilloverAmount > totalAvailable) {
            spilloverAmount = totalAvailable - 10000; // Leave small buffer
        }

        console.log("Available in slot 0:", availableInSlot0);
        console.log("Planned consumption (with spillover):", spilloverAmount);

        // Log before consumption
        _logSlotStates(poolId, 2, 3, "BEFORE cross-slot spillover");

        _executeCachedConsumption(poolId, sender, spilloverAmount, 3);

        // Log after consumption
        _logSlotStates(poolId, 2, 3, "AFTER cross-slot spillover");

        // Verify spillover occurred
        uint256 finalUsage0 = paymaster.nullifierGasUsage(nullifier0);
        uint256 finalUsage1 = paymaster.nullifierGasUsage(nullifier1);

        // Slot 0 should have increased usage
        assertGt(
            finalUsage0,
            initialUsage0,
            "Slot 0 should have increased usage"
        );

        // If spillover occurred, slot 1 should also have increased
        if (spilloverAmount > availableInSlot0) {
            assertGt(
                finalUsage1,
                initialUsage1,
                "Slot 1 should have consumed spillover"
            );
        }

        console.log("Cross-slot spillover successful");
    }

    /// @dev Test consumption follows activeNullifierIndex order
    function test_TwoSlotConsumption_FromNearlyExhaustedSlot() public {
        uint256 poolId = poolId3;
        address sender = sender3;

        console.log(
            "=== Two-Slot Consumption: Nearly Exhausted Slot Logic ==="
        );

        // Setup: Activate two nullifiers
        _activateTwoNullifiers(poolId, sender, 4, 5);

        // Consume most of slot 0's budget
        _consumeMostOfSlot0(poolId, sender, 4);

        // Log before test consumption
        _logSlotStates(poolId, 4, 5, "BEFORE nearly exhausted slot test");

        // Get current state for assertions
        uint256 nullifier0 = getNullifier(4);
        uint256 nullifier1 = getNullifier(5);
        uint256 usage0Before = paymaster.nullifierGasUsage(nullifier0);
        uint256 usage1Before = paymaster.nullifierGasUsage(nullifier1);

        // Execute consumption that should still go to slot 0 (since it has budget left)
        // The algorithm follows activeNullifierIndex=0, so it uses slot 0 first
        _executeCachedConsumption(poolId, sender, 30000, 4);

        // Log after test consumption
        _logSlotStates(poolId, 4, 5, "AFTER nearly exhausted slot test");

        // Verify consumption went to slot 0 (not slot 1) because that's the algorithm
        uint256 usage0After = paymaster.nullifierGasUsage(nullifier0);
        uint256 usage1After = paymaster.nullifierGasUsage(nullifier1);

        assertGt(
            usage0After,
            usage0Before,
            "Slot 0 should have increased (it still has budget)"
        );
        assertEq(
            usage1After,
            usage1Before,
            "Slot 1 should be unchanged (slot 0 not exhausted)"
        );

        console.log(
            "Consumption followed activeNullifierIndex order as expected"
        );
    }

    /// @dev Test slot state management when approaching budget limits
    function test_TwoSlotConsumption_ExhaustionState() public {
        uint256 poolId = poolId1;
        address sender = makeAddr("exhaustionSender");

        console.log(
            "=== Two-Slot Consumption: Exhaustion State Management ==="
        );

        // Setup: Activate single nullifier first
        _activateSingleNullifier(poolId, sender, 6);

        uint256 joiningFee = paymaster.getJoiningFee(poolId);
        uint256 nullifier = getNullifier(6);

        // Consume most of the nullifier's budget (but not exceed it)
        uint256 currentUsage = paymaster.nullifierGasUsage(nullifier);
        uint256 remainingBudget = joiningFee - currentUsage;
        uint256 gasToConsume = (remainingBudget * 90) / 100; // Use 90% of remaining

        // Log before consumption
        _logSingleSlotState(poolId, 6, "BEFORE exhaustion state test");

        _executeCachedConsumption(poolId, sender, gasToConsume, 1);

        // Log after consumption
        _logSingleSlotState(poolId, 6, "AFTER exhaustion state test");

        // Verify the nullifier is nearly exhausted but still valid
        uint256 finalUsage = paymaster.nullifierGasUsage(nullifier);
        uint256 finalRemaining = joiningFee - finalUsage;

        console.log("Final remaining budget:", finalRemaining);
        assertLt(
            finalRemaining,
            remainingBudget / 2,
            "Should have consumed most budget"
        );
        assertGt(finalRemaining, 0, "Should still have some budget left");

        // Verify state shows proper management
        bytes32 userStateKey = getUserStateKey(sender, poolId);
        uint256 state = paymaster.userNullifiersStates(userStateKey);
        assertEq(
            state.getActivatedNullifierCount(),
            1,
            "Should still have 1 active nullifier"
        );

        console.log("Exhaustion state management successful");
    }

    // ============ Helper Functions ============

    /// @dev Activate two nullifiers in slots 0 and 1
    function _activateTwoNullifiers(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex0,
        uint256 nullifierIndex1
    ) internal {
        // Activate first nullifier
        bytes memory context1 = createFirstActivationContext(
            poolId,
            sender,
            nullifierIndex0,
            0
        );
        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            context1,
            100000,
            20 gwei
        );

        // Activate second nullifier
        bytes32 userStateKey = getUserStateKey(sender, poolId);
        uint256 currentState = paymaster.userNullifiersStates(userStateKey);

        bytes memory context2 = createActivationContextWithState(
            poolId,
            sender,
            nullifierIndex1,
            1,
            currentState
        );
        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            context2,
            100000,
            20 gwei
        );
    }

    /// @dev Activate single nullifier
    function _activateSingleNullifier(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex
    ) internal {
        bytes memory context = createFirstActivationContext(
            poolId,
            sender,
            nullifierIndex,
            0
        );
        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            context,
            100000,
            20 gwei
        );
    }

    /// @dev Execute cached consumption
    function _executeCachedConsumption(
        uint256 poolId,
        address sender,
        uint256 actualGasCost,
        uint256 userOpHashIndex
    ) internal {
        bytes32 userStateKey = getUserStateKey(sender, poolId);
        uint256 state = paymaster.userNullifiersStates(userStateKey);
        uint8 activatedCount = state.getActivatedNullifierCount();

        bytes memory cachedContext = createCachedConsumptionContext(
            poolId,
            sender,
            activatedCount,
            0, // activeIndex
            userOpHashIndex
        );

        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            cachedContext,
            actualGasCost,
            20 gwei
        );
    }

    /// @dev Consume most of slot 0's available budget (within user limits)
    function _consumeMostOfSlot0(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex
    ) internal {
        uint256 joiningFee = paymaster.getJoiningFee(poolId);
        uint256 nullifier = getNullifier(nullifierIndex);
        uint256 currentUsage = paymaster.nullifierGasUsage(nullifier);
        uint256 remainingInSlot0 = joiningFee - currentUsage;

        // Consume 70% of remaining budget (respects user limits)
        uint256 gasToConsume = (remainingInSlot0 * 70) / 100;

        if (gasToConsume > 30000) {
            // Only if meaningful amount
            _executeCachedConsumption(poolId, sender, gasToConsume, 1);
        }
    }

    /// @dev Create activation context with specific state
    function createActivationContextWithState(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 userOpHashIndex,
        uint256 currentState
    ) internal view returns (bytes memory context) {
        require(
            nullifierIndex < nullifiers.length,
            "Nullifier index out of bounds"
        );
        require(
            userOpHashIndex < userOpHashes.length,
            "UserOp hash index out of bounds"
        );

        uint256 nullifier = nullifiers[nullifierIndex];
        bytes32 userOpHash = userOpHashes[userOpHashIndex];
        bytes32 userStateKey = keccak256(abi.encode(poolId, sender));

        context = PostOpContextLib.encodeActivationContext(
            poolId,
            userOpHash,
            nullifier,
            currentState,
            userStateKey,
            sender
        );

        require(context.length == 181, "Invalid activation context length");
    }

    // ============ Logging Helper Functions ============

    /// @dev Log gas state for both slots
    function _logSlotStates(
        uint256 poolId,
        uint256 nullifierIndex0,
        uint256 nullifierIndex1,
        string memory label
    ) internal view {
        uint256 joiningFee = paymaster.getJoiningFee(poolId);
        uint256 nullifier0 = getNullifier(nullifierIndex0);
        uint256 nullifier1 = getNullifier(nullifierIndex1);

        uint256 usage0 = paymaster.nullifierGasUsage(nullifier0);
        uint256 usage1 = paymaster.nullifierGasUsage(nullifier1);
        uint256 available0 = joiningFee - usage0;
        uint256 available1 = joiningFee - usage1;

        console.log("");
        console.log("--- Slot States:", label, "---");
        console.log("Slot 0 (nullifier", nullifierIndex0, "):");
        console.log("  Gas used:", usage0);
        console.log("  Gas available:", available0);
        console.log("Slot 1 (nullifier", nullifierIndex1, "):");
        console.log("  Gas used:", usage1);
        console.log("  Gas available:", available1);
        console.log("Total available:", available0 + available1);
        console.log("-------------------------------");
    }

    /// @dev Log gas state for single slot
    function _logSingleSlotState(
        uint256 poolId,
        uint256 nullifierIndex,
        string memory label
    ) internal view {
        uint256 joiningFee = paymaster.getJoiningFee(poolId);
        uint256 nullifier = getNullifier(nullifierIndex);
        uint256 usage = paymaster.nullifierGasUsage(nullifier);
        uint256 available = joiningFee - usage;

        console.log("");
        console.log("--- Single Slot State:", label, "---");
        console.log("Slot (nullifier", nullifierIndex, "):");
        console.log("  Joining fee:", joiningFee);
        console.log("  Gas used:", usage);
        console.log("  Gas available:", available);
        console.log("  Usage percentage:", (usage * 100) / joiningFee, "%");
        console.log("--------------------------------");
    }
}
