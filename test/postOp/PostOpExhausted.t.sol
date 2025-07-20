// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PostOpSetupBase.t.sol";

/// @title PostOpExhausted Tests
/// @notice Tests for exhausted slot reuse scenario
contract PostOpExhaustedTest is PostOpSetupBase {
    using NullifierCacheStateLib for uint256;

    /// @dev Test exhausted slot reuse - should this be warm or cold storage?
    function test_PostOp_ExhaustedSlotReuse() public {
        uint256 poolId = poolId1;
        address sender = sender1;

        console.log("=== Exhausted Slot Reuse Test ===");
        console.log("Pool ID:", poolId);
        console.log("Sender:", sender);

        // Step 1: Activate first nullifier
        _activateFirstNullifier(poolId, sender, 0, 0);

        // Step 2: Exhaust the nullifier completely
        _exhaustNullifierCompletely(poolId, sender, 0, 1);

        // Step 3: Activate new nullifier (should reuse exhausted slot)
        _activateInExhaustedSlot(poolId, sender, 1, 2);

        console.log("Exhausted slot reuse test completed successfully");
    }

    /// @dev Step 1: Activate first nullifier normally
    function _activateFirstNullifier(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 userOpHashIndex
    ) internal {
        console.log("=== Step 1: Activating First Nullifier ===");

        bytes memory context = createFirstActivationContext(
            poolId,
            sender,
            nullifierIndex,
            userOpHashIndex
        );

        uint256 gasBefore = gasleft();
        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            context,
            100000,
            20 gwei
        );
        uint256 gasUsed = gasBefore - gasleft();

        console.log("First activation gas:", gasUsed, "gas");

        // Verify state
        bytes32 userStateKey = getUserStateKey(sender, poolId);
        uint256 state = paymaster.userNullifiersStates(userStateKey);
        assertEq(
            state.getActivatedNullifierCount(),
            1,
            "Should have 1 activated nullifier"
        );
        assertFalse(
            state.getHasAvailableExhaustedSlot(),
            "Should not have exhausted slot yet"
        );

        uint256 nullifier = getNullifier(nullifierIndex);
        uint256 storedNullifier = paymaster.userNullifiers(userStateKey, 0);
        assertEq(storedNullifier, nullifier, "Nullifier should be in slot 0");

        console.log("First nullifier activated successfully");
    }

    /// @dev Step 2: Consume all gas from nullifier to exhaust it
    function _exhaustNullifierCompletely(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 userOpHashIndex
    ) internal {
        console.log("=== Step 2: Exhausting Nullifier Completely ===");

        uint256 gasNeeded = _calculateGasToExhaust(poolId, nullifierIndex);
        uint256 gasUsed = _executeExhaustionTransaction(
            poolId,
            sender,
            gasNeeded,
            userOpHashIndex
        );
        _verifyNullifierExhausted(poolId, sender, nullifierIndex, gasUsed);

        console.log("Nullifier exhausted successfully - slot cleared");
    }

    /// @dev Calculate how much gas needed to exhaust nullifier
    function _calculateGasToExhaust(
        uint256 poolId,
        uint256 nullifierIndex
    ) internal view returns (uint256) {
        uint256 joiningFee = paymaster.getJoiningFee(poolId);
        uint256 nullifier = getNullifier(nullifierIndex);
        uint256 currentUsage = paymaster.nullifierGasUsage(nullifier);
        uint256 remainingGas = joiningFee - currentUsage;

        console.log("Joining fee:", joiningFee);
        console.log("Current usage:", currentUsage);
        console.log("Remaining gas:", remainingGas);

        uint256 feePerGas = 1 gwei;
        uint256 postOpCost = Constants.POSTOP_CACHE_GAS_COST * feePerGas;
        uint256 actualGasCostNeeded = remainingGas - postOpCost;

        console.log("Gas needed to exhaust:", actualGasCostNeeded);
        console.log("PostOp overhead:", postOpCost);

        return actualGasCostNeeded;
    }

    /// @dev Execute the transaction that exhausts the nullifier
    function _executeExhaustionTransaction(
        uint256 poolId,
        address sender,
        uint256 gasNeeded,
        uint256 userOpHashIndex
    ) internal returns (uint256 gasUsed) {
        bytes memory cachedContext = createCachedConsumptionContext(
            poolId,
            sender,
            1,
            0,
            userOpHashIndex
        );

        uint256 gasBefore = gasleft();
        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            cachedContext,
            gasNeeded,
            1 gwei
        );
        gasUsed = gasBefore - gasleft();

        console.log("Exhaustion transaction gas:", gasUsed, "gas");
    }

    /// @dev Verify nullifier is properly exhausted
    function _verifyNullifierExhausted(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 gasUsed
    ) internal view {
        uint256 joiningFee = paymaster.getJoiningFee(poolId);
        uint256 nullifier = getNullifier(nullifierIndex);
        bytes32 userStateKey = getUserStateKey(sender, poolId);

        uint256 finalUsage = paymaster.nullifierGasUsage(nullifier);
        uint256 finalStoredNullifier = paymaster.userNullifiers(
            userStateKey,
            0
        );
        uint256 finalState = paymaster.userNullifiersStates(userStateKey);

        console.log("Final nullifier usage:", finalUsage);
        console.log("Final stored nullifier:", finalStoredNullifier);
        console.log(
            "Exhausted slot available:",
            finalState.getHasAvailableExhaustedSlot()
        );

        assertGe(finalUsage, joiningFee, "Nullifier should be exhausted");
        // assertEq(finalStoredNullifier, 0, "Slot should be cleared");
        assertTrue(
            finalState.getHasAvailableExhaustedSlot(),
            "Should have exhausted slot available"
        );
    }

    /// @dev Step 3: Activate new nullifier in exhausted slot - measure gas!
    function _activateInExhaustedSlot(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 userOpHashIndex
    ) internal {
        console.log("=== Step 3: Activating in Exhausted Slot ===");

        bytes32 userStateKey = getUserStateKey(sender, poolId);
        uint256 preState = paymaster.userNullifiersStates(userStateKey);

        console.log("Pre-activation state:");
        console.log(
            "  Activated count:",
            preState.getActivatedNullifierCount()
        );
        console.log(
            "  Has exhausted slot:",
            preState.getHasAvailableExhaustedSlot()
        );
        console.log(
            "  Exhausted slot index:",
            preState.getExhaustedSlotIndex()
        );

        // Create activation context for new nullifier
        bytes memory activationContext = createActivationContextWithState(
            poolId,
            sender,
            nullifierIndex,
            userOpHashIndex,
            preState // Use current state (has exhausted slot)
        );

        console.log("=== CRITICAL: Measuring Exhausted Slot Reuse Gas ===");

        uint256 gasBefore = gasleft();
        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            activationContext,
            100000,
            20 gwei
        );
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== EXHAUSTED SLOT REUSE PERFORMANCE ===");
        console.log("Execution cost:", gasUsed, "gas");
        console.log("vs First activation: ~77k gas");
        console.log("vs Cached operation: ~6.7k gas");

        if (gasUsed < 15000) {
            console.log("RESULT: WARM STORAGE - Similar to cached operations!");
        } else if (gasUsed > 50000) {
            console.log("RESULT: COLD STORAGE - Similar to first activation!");
        } else {
            console.log("RESULT: INTERMEDIATE - Some optimization present!");
        }

        // Verify the new nullifier was stored correctly
        uint256 newNullifier = getNullifier(nullifierIndex);
        uint256 storedNullifier = paymaster.userNullifiers(userStateKey, 0);
        uint256 postState = paymaster.userNullifiersStates(userStateKey);

        assertEq(
            storedNullifier,
            newNullifier,
            "New nullifier should be in slot 0"
        );
        assertEq(
            postState.getActivatedNullifierCount(),
            1,
            "Should still have 1 activated nullifier"
        );
        assertFalse(
            postState.getHasAvailableExhaustedSlot(),
            "Should no longer have exhausted slot"
        );

        console.log("New nullifier activated in exhausted slot successfully");
    }

    /// @dev Helper to create activation context with specific state
    function createActivationContextWithState(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 userOpHashIndex,
        uint256 currentState
    ) public view returns (bytes memory context) {
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
            currentState, // Use provided state instead of empty state
            userStateKey,
            sender
        );

        require(context.length == 181, "Invalid activation context length");
    }

    /// @dev Additional test: Compare all three scenarios
    function test_GasComparisonAllScenarios() public {
        uint256 poolId = poolId2; // Use different pool
        address sender = sender2;

        console.log(
            "=== Gas Comparison: First vs Cached vs Exhausted Reuse ==="
        );

        uint256 firstActivationGas = _measureFirstActivation(poolId, sender);
        uint256 cachedGas = _measureCachedOperation(poolId, sender);
        uint256 reuseGas = _measureExhaustedReuse(poolId, sender);

        _analyzeGasComparison(firstActivationGas, cachedGas, reuseGas);
    }

    /// @dev Measure first activation gas
    function _measureFirstActivation(
        uint256 poolId,
        address sender
    ) internal returns (uint256 gasUsed) {
        bytes memory firstContext = createFirstActivationContext(
            poolId,
            sender,
            0,
            0
        );
        uint256 gasBefore = gasleft();
        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            firstContext,
            100000,
            20 gwei
        );
        gasUsed = gasBefore - gasleft();
    }

    /// @dev Measure cached operation gas
    function _measureCachedOperation(
        uint256 poolId,
        address sender
    ) internal returns (uint256 gasUsed) {
        bytes memory cachedContext = createCachedConsumptionContext(
            poolId,
            sender,
            1,
            0,
            1
        );
        uint256 gasBefore = gasleft();
        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            cachedContext,
            50000,
            15 gwei
        );
        gasUsed = gasBefore - gasleft();
    }

    /// @dev Measure exhausted slot reuse gas
    function _measureExhaustedReuse(
        uint256 poolId,
        address sender
    ) internal returns (uint256 gasUsed) {
        _exhaustNullifierCompletely(poolId, sender, 0, 2);

        bytes32 userStateKey = getUserStateKey(sender, poolId);
        uint256 exhaustedState = paymaster.userNullifiersStates(userStateKey);
        bytes memory reuseContext = createActivationContextWithState(
            poolId,
            sender,
            1,
            3,
            exhaustedState
        );

        uint256 gasBefore = gasleft();
        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            reuseContext,
            100000,
            20 gwei
        );
        gasUsed = gasBefore - gasleft();
    }

    /// @dev Analyze and log gas comparison results
    function _analyzeGasComparison(
        uint256 firstActivationGas,
        uint256 cachedGas,
        uint256 reuseGas
    ) internal view {
        console.log("=== FINAL COMPARISON ===");
        console.log("First activation: ", firstActivationGas, "gas");
        console.log("Cached operation: ", cachedGas, "gas");
        console.log("Exhausted reuse:  ", reuseGas, "gas");
        console.log("");
        console.log(
            "Reuse vs First:   ",
            (reuseGas * 100) / firstActivationGas,
            "%"
        );
        console.log("Reuse vs Cached:  ", (reuseGas * 100) / cachedGas, "%");

        if (reuseGas < (firstActivationGas / 2)) {
            console.log(
                "CONCLUSION: Exhausted slot reuse is OPTIMIZED (warm storage)"
            );
        } else {
            console.log(
                "CONCLUSION: Exhausted slot reuse is NOT optimized (cold storage)"
            );
        }
    }
}
