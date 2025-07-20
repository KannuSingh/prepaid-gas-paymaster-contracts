// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PostOpSetupBase.t.sol";

/// @title PostOpSecondNullifier Tests
/// @notice Test second nullifier activation in 2-slot system
contract PostOpSecondNullifierTest is PostOpSetupBase {
    using NullifierCacheStateLib for uint256;

    /// @dev Test activating second nullifier when first is already active
    function test_PostOp_SecondNullifierActivation() public {
        uint256 poolId = poolId1;
        address sender = sender1;

        console.log("=== Second Nullifier Activation Test ===");
        console.log("Pool ID:", poolId);
        console.log("Sender:", sender);

        // Step 1: Activate first nullifier (baseline)
        uint256 firstActivationGas = _activateFirstNullifier(
            poolId,
            sender,
            0,
            0
        );

        // Step 2: Activate second nullifier (slot 1)
        uint256 secondActivationGas = _activateSecondNullifier(
            poolId,
            sender,
            1,
            1
        );

        // Step 3: Verify both nullifiers are active
        _verifyTwoSlotState(poolId, sender, 0, 1);

        // Step 4: Compare gas costs
        _analyzeSecondActivationGas(firstActivationGas, secondActivationGas);

        console.log("Second nullifier activation test completed successfully");
    }

    /// @dev Activate first nullifier and return gas cost
    function _activateFirstNullifier(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 userOpHashIndex
    ) internal returns (uint256 gasUsed) {
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
        gasUsed = gasBefore - gasleft();

        console.log("First activation gas:", gasUsed, "gas");

        // Verify first nullifier state
        bytes32 userStateKey = getUserStateKey(sender, poolId);
        uint256 state = paymaster.userNullifiersStates(userStateKey);
        assertEq(
            state.getActivatedNullifierCount(),
            1,
            "Should have 1 activated nullifier"
        );
        assertEq(
            state.getActiveNullifierIndex(),
            0,
            "Should start consuming from slot 0"
        );

        uint256 nullifier = getNullifier(nullifierIndex);
        uint256 storedNullifier = paymaster.userNullifiers(userStateKey, 0);
        assertEq(
            storedNullifier,
            nullifier,
            "First nullifier should be in slot 0"
        );

        console.log("First nullifier activated successfully in slot 0");
    }

    /// @dev Activate second nullifier and return gas cost
    function _activateSecondNullifier(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 userOpHashIndex
    ) internal returns (uint256 gasUsed) {
        console.log("=== Step 2: Activating Second Nullifier ===");

        bytes32 userStateKey = getUserStateKey(sender, poolId);
        uint256 currentState = paymaster.userNullifiersStates(userStateKey);

        console.log("Pre-second-activation state:");
        console.log(
            "  Activated count:",
            currentState.getActivatedNullifierCount()
        );
        console.log("  Active index:", currentState.getActiveNullifierIndex());
        console.log(
            "  Has exhausted slot:",
            currentState.getHasAvailableExhaustedSlot()
        );

        // Create activation context with current state (1 nullifier already active)
        bytes memory context = createActivationContextWithState(
            poolId,
            sender,
            nullifierIndex,
            userOpHashIndex,
            currentState
        );

        console.log(
            "=== CRITICAL: Measuring Second Nullifier Activation Gas ==="
        );

        uint256 gasBefore = gasleft();
        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            context,
            120000,
            25 gwei
        );
        gasUsed = gasBefore - gasleft();

        console.log("=== SECOND NULLIFIER PERFORMANCE ===");
        console.log("Execution cost:", gasUsed, "gas");

        uint256 nullifier = getNullifier(nullifierIndex);
        uint256 storedNullifier = paymaster.userNullifiers(userStateKey, 1);
        assertEq(
            storedNullifier,
            nullifier,
            "Second nullifier should be in slot 1"
        );

        console.log("Second nullifier activated successfully in slot 1");
    }

    /// @dev Verify both nullifiers are active in correct slots
    function _verifyTwoSlotState(
        uint256 poolId,
        address sender,
        uint256 firstNullifierIndex,
        uint256 secondNullifierIndex
    ) internal view {
        console.log("=== Step 3: Verifying Two-Slot State ===");

        bytes32 userStateKey = getUserStateKey(sender, poolId);
        uint256 finalState = paymaster.userNullifiersStates(userStateKey);

        // State verification
        uint8 activatedCount = finalState.getActivatedNullifierCount();
        uint8 activeIndex = finalState.getActiveNullifierIndex();
        bool hasExhausted = finalState.getHasAvailableExhaustedSlot();

        assertEq(activatedCount, 2, "Should have 2 activated nullifiers");
        assertEq(activeIndex, 0, "Should still start consuming from slot 0");
        assertFalse(hasExhausted, "Should not have exhausted slot");

        // Slot verification
        uint256 firstNullifier = getNullifier(firstNullifierIndex);
        uint256 secondNullifier = getNullifier(secondNullifierIndex);

        uint256 storedFirst = paymaster.userNullifiers(userStateKey, 0);
        uint256 storedSecond = paymaster.userNullifiers(userStateKey, 1);

        assertEq(
            storedFirst,
            firstNullifier,
            "First nullifier should be in slot 0"
        );
        assertEq(
            storedSecond,
            secondNullifier,
            "Second nullifier should be in slot 1"
        );

        // Gas usage verification
        uint256 firstUsage = paymaster.nullifierGasUsage(firstNullifier);
        uint256 secondUsage = paymaster.nullifierGasUsage(secondNullifier);

        assertGt(firstUsage, 0, "First nullifier should have gas usage");
        assertGt(secondUsage, 0, "Second nullifier should have gas usage");

        console.log("Final state verification:");
        console.log("  Activated count:", activatedCount);
        console.log("  Active index:", activeIndex);
        console.log("  Slot 0 nullifier:", storedFirst);
        console.log("  Slot 1 nullifier:", storedSecond);
        console.log("  Slot 0 gas usage:", firstUsage);
        console.log("  Slot 1 gas usage:", secondUsage);

        console.log("Two-slot state verified successfully");
    }

    /// @dev Analyze gas cost difference between first and second activation
    function _analyzeSecondActivationGas(
        uint256 firstActivationGas,
        uint256 secondActivationGas
    ) internal view {
        console.log("=== Step 4: Second Activation Gas Analysis ===");
        console.log("First activation: ", firstActivationGas, "gas");
        console.log("Second activation:", secondActivationGas, "gas");

        if (secondActivationGas < firstActivationGas) {
            uint256 savings = firstActivationGas - secondActivationGas;
            console.log("Second is CHEAPER by:", savings, "gas");
            console.log(
                "Savings percentage:",
                (savings * 100) / firstActivationGas,
                "%"
            );

            if (savings > 20000) {
                console.log(
                    "RESULT: Significant optimization for second activation!"
                );
            } else if (savings > 5000) {
                console.log(
                    "RESULT: Moderate optimization for second activation"
                );
            } else {
                console.log("RESULT: Minor optimization for second activation");
            }
        } else if (secondActivationGas > firstActivationGas) {
            uint256 extra = secondActivationGas - firstActivationGas;
            console.log("Second is MORE EXPENSIVE by:", extra, "gas");
            console.log(
                "Extra percentage:",
                (extra * 100) / firstActivationGas,
                "%"
            );
            console.log("RESULT: Second activation has overhead");
        } else {
            console.log("RESULT: Identical gas costs");
        }

        // Storage pattern analysis
        console.log("=== Storage Pattern Analysis ===");
        console.log(
            "First activation: Empty slot 0 -> nullifier (cold storage)"
        );
        console.log(
            "Second activation: Empty slot 1 -> nullifier (cold or warm?)"
        );

        if (secondActivationGas < (firstActivationGas * 80) / 100) {
            console.log(
                "CONCLUSION: Slot 1 benefits from warm storage optimization"
            );
        } else {
            console.log("CONCLUSION: Slot 1 follows cold storage pattern");
        }
    }

    /// @dev Helper to create activation context with specific state (moved from exhausted test)
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

    /// @dev Test sequential activations in same transaction
    function test_SequentialActivations() public {
        uint256 poolId = poolId2; // Different pool
        address sender = sender2;

        console.log("=== Sequential Activations Test ===");

        // Quick sequence: first → second → verify
        uint256 gas1 = _measureSingleActivation(poolId, sender, 0, 0, "First");
        uint256 gas2 = _measureSingleActivation(poolId, sender, 1, 1, "Second");

        console.log("=== SEQUENTIAL COMPARISON ===");
        console.log("First sequential: ", gas1, "gas");
        console.log("Second sequential:", gas2, "gas");
        console.log(
            "Difference:",
            gas1 > gas2 ? gas1 - gas2 : gas2 - gas1,
            "gas"
        );

        // Verify final state
        bytes32 userStateKey = getUserStateKey(sender, poolId);
        uint256 finalState = paymaster.userNullifiersStates(userStateKey);
        assertEq(
            finalState.getActivatedNullifierCount(),
            2,
            "Should have 2 nullifiers after sequence"
        );
    }

    /// @dev Helper to measure single activation gas
    function _measureSingleActivation(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 userOpHashIndex,
        string memory label
    ) internal returns (uint256 gasUsed) {
        bytes32 userStateKey = getUserStateKey(sender, poolId);
        uint256 currentState = paymaster.userNullifiersStates(userStateKey);

        bytes memory context = createActivationContextWithState(
            poolId,
            sender,
            nullifierIndex,
            userOpHashIndex,
            currentState
        );

        uint256 gasBefore = gasleft();
        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            context,
            100000,
            20 gwei
        );
        gasUsed = gasBefore - gasleft();

        console.log(label, "activation gas:", gasUsed);
    }
}
