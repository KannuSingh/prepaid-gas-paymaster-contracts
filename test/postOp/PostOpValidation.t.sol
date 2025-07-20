// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PostOpSetupBase.t.sol";

/// @title PostOpValidation Tests
/// @notice Logic validation and gas analysis tests
contract PostOpValidationTest is PostOpSetupBase {
    using NullifierCacheStateLib for uint256;

    /// @dev Validate activation flow creates nullifier correctly
    function test_ActivationLogicValidation() public {
        uint256 poolId = poolId2;
        address sender = sender2;
        bytes32 userStateKey = getUserStateKey(sender, poolId);

        // Pre-conditions: Empty state
        assertEq(
            paymaster.userNullifiersStates(userStateKey),
            0,
            "Should start empty"
        );
        assertEq(
            paymaster.userNullifiers(userStateKey, 0),
            0,
            "Slot 0 should be empty"
        );
        assertEq(
            paymaster.userNullifiers(userStateKey, 1),
            0,
            "Slot 1 should be empty"
        );

        uint256 testNullifier = getNullifier(0);
        assertEq(
            paymaster.nullifierGasUsage(testNullifier),
            0,
            "Nullifier should have no usage"
        );

        // Execute activation
        bytes memory context = createFirstActivationContext(
            poolId,
            sender,
            0,
            0
        );
        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            context,
            100000,
            20 gwei
        );

        // Post-conditions: Nullifier created and state set correctly
        uint256 finalState = paymaster.userNullifiersStates(userStateKey);
        assertEq(
            finalState.getActivatedNullifierCount(),
            1,
            "Should have 1 activated nullifier"
        );
        assertEq(
            finalState.getActiveNullifierIndex(),
            0,
            "Should start consuming from slot 0"
        );
        assertFalse(
            finalState.getHasAvailableExhaustedSlot(),
            "Should not have exhausted slot"
        );

        assertEq(
            paymaster.userNullifiers(userStateKey, 0),
            testNullifier,
            "Nullifier should be in slot 0"
        );
        assertEq(
            paymaster.userNullifiers(userStateKey, 1),
            0,
            "Slot 1 should still be empty"
        );

        uint256 expectedGasCost = 100000 +
            (Constants.POSTOP_ACTIVATION_GAS_COST * 20 gwei);
        assertEq(
            paymaster.nullifierGasUsage(testNullifier),
            expectedGasCost,
            "Gas usage should match expected"
        );

        console.log("Activation logic validation passed");
    }

    /// @dev Validate cached flow consumes from existing nullifier correctly
    function test_CachedLogicValidation() public {
        uint256 poolId = poolId2;
        address sender = sender2;
        bytes32 userStateKey = getUserStateKey(sender, poolId);

        // Setup: First activate a nullifier
        bytes memory activationContext = createFirstActivationContext(
            poolId,
            sender,
            0,
            0
        );
        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            activationContext,
            100000,
            20 gwei
        );

        // Pre-conditions: 1 activated nullifier exists
        uint256 preState = paymaster.userNullifiersStates(userStateKey);
        assertEq(
            preState.getActivatedNullifierCount(),
            1,
            "Should have 1 activated nullifier"
        );

        uint256 testNullifier = getNullifier(0);
        uint256 preGasUsage = paymaster.nullifierGasUsage(testNullifier);
        assertGt(preGasUsage, 0, "Nullifier should have initial gas usage");

        // Execute cached consumption
        bytes memory cachedContext = createCachedConsumptionContext(
            poolId,
            sender,
            1,
            0,
            1
        );
        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            cachedContext,
            80000,
            15 gwei
        );

        // Post-conditions: Same nullifier, increased usage, no new nullifiers
        uint256 postState = paymaster.userNullifiersStates(userStateKey);
        assertEq(
            postState.getActivatedNullifierCount(),
            1,
            "Should still have 1 activated nullifier"
        );
        assertEq(
            postState.getActiveNullifierIndex(),
            0,
            "Should still consume from slot 0"
        );

        assertEq(
            paymaster.userNullifiers(userStateKey, 0),
            testNullifier,
            "Same nullifier in slot 0"
        );
        assertEq(
            paymaster.userNullifiers(userStateKey, 1),
            0,
            "Slot 1 should still be empty"
        );

        uint256 postGasUsage = paymaster.nullifierGasUsage(testNullifier);
        uint256 expectedIncrease = 80000 +
            (Constants.POSTOP_CACHE_GAS_COST * 15 gwei);
        assertEq(
            postGasUsage,
            preGasUsage + expectedIncrease,
            "Gas usage should increase by expected amount"
        );

        console.log("Cached logic validation passed");
    }

    /// @dev Analyze gas consumption breakdown for activation vs cached
    function test_GasAnalysisBreakdown() public {
        uint256 poolId = poolId3;
        address sender = sender3;

        console.log("=== Gas Analysis: Activation vs Cached ===");

        // ============ Activation Gas Analysis ============
        console.log("--- Activation Gas Breakdown ---");

        bytes memory activationContext = createFirstActivationContext(
            poolId,
            sender,
            0,
            0
        );

        uint256 totalGasBefore = gasleft();

        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            activationContext,
            100000,
            20 gwei
        );

        uint256 totalActivationGas = totalGasBefore - gasleft();
        console.log("Total activation gas:", totalActivationGas, "gas");

        // ============ Cached Gas Analysis ============
        console.log("--- Cached Gas Breakdown ---");

        bytes memory cachedContext = createCachedConsumptionContext(
            poolId,
            sender,
            1,
            0,
            1
        );

        uint256 cachedTotalGasBefore = gasleft();

        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            cachedContext,
            80000,
            15 gwei
        );

        uint256 totalCachedGas = cachedTotalGasBefore - gasleft();
        console.log("Total cached gas:", totalCachedGas, "gas");

        // ============ Analysis ============
        console.log("--- Gas Difference Analysis ---");
        console.log("Activation gas:", totalActivationGas);
        console.log("Cached gas:", totalCachedGas);
        console.log("Difference:", totalActivationGas - totalCachedGas, "gas");
        console.log(
            "Multiplier:",
            (totalActivationGas * 100) / totalCachedGas,
            "% (cached = 100%)"
        );

        console.log("=== Key Operations Analysis ===");
        console.log(
            "Activation: Creates new nullifier storage + initializes state"
        );
        console.log(
            "Cached: Updates existing nullifier usage + simple state update"
        );
        console.log("Major cost difference likely from:");
        console.log("  - Cold storage writes (new nullifier): ~20k gas");
        console.log("  - State initialization complexity: ~40k+ gas");
        console.log("  - Additional validation overhead");
    }

    /// @dev Test basic setup verification
    function test_SetupCorrect() public view {
        assertTrue(address(paymaster) != address(0));
        assertTrue(address(mockEntryPoint) != address(0));
        assertTrue(address(mockVerifier) != address(0));

        console.log("Setup verification passed");
    }
}
