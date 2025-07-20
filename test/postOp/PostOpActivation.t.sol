// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PostOpSetupBase.t.sol";

/// @title PostOpActivation Tests
/// @notice Focused tests for activation flow
contract PostOpActivationTest is PostOpSetupBase {
    using NullifierCacheStateLib for uint256;

    /// @dev Test first nullifier activation flow
    function test_PostOp_FirstActivation() public {
        uint256 poolId = poolId1;
        address sender = sender1;
        uint256 nullifierIndex = 0;
        uint256 userOpHashIndex = 0;

        console.log("=== First Activation Test ===");
        console.log("Pool ID:", poolId);
        console.log("Sender:", sender);

        _testFirstActivationSetup(poolId, sender, nullifierIndex);
        _testFirstActivationExecution(
            poolId,
            sender,
            nullifierIndex,
            userOpHashIndex
        );
        _testFirstActivationVerification(poolId, sender, nullifierIndex);

        console.log("First activation test completed successfully");
    }

    function _testFirstActivationSetup(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex
    ) internal view {
        bytes32 userStateKey = getUserStateKey(sender, poolId);

        uint256 initialNullifierState = paymaster.userNullifiersStates(
            userStateKey
        );
        assertEq(
            initialNullifierState,
            0,
            "Initial nullifier state should be empty"
        );

        uint256 nullifier = getNullifier(nullifierIndex);
        uint256 initialNullifierGasUsage = paymaster.nullifierGasUsage(
            nullifier
        );
        assertEq(
            initialNullifierGasUsage,
            0,
            "Nullifier should have no initial gas usage"
        );

        console.log("=== Initial State Verified ===");
    }

    function _testFirstActivationExecution(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 userOpHashIndex
    ) internal {
        uint256 actualGasCost = 150000;
        uint256 actualUserOpFeePerGas = 20 gwei;

        console.log("Actual gas cost:", actualGasCost);
        console.log("Gas price:", actualUserOpFeePerGas);

        bytes memory context = createFirstActivationContext(
            poolId,
            sender,
            nullifierIndex,
            userOpHashIndex
        );

        assertEq(context.length, 181, "Context should be 181 bytes");
        assertTrue(
            isActivationContext(context),
            "Should be activation context"
        );
        assertEq(
            getPoolIdFromContext(context),
            poolId,
            "Context pool ID should match"
        );

        uint256 expectedPostOpGas = Constants.POSTOP_ACTIVATION_GAS_COST *
            actualUserOpFeePerGas;
        uint256 expectedTotalGasCost = actualGasCost + expectedPostOpGas;

        console.log("=== About to call postOp ===");

        vm.expectEmit(true, true, false, false);
        emit UserOpSponsoredActivation(
            getUserOpHash(userOpHashIndex),
            poolId,
            sender,
            expectedTotalGasCost,
            getNullifier(nullifierIndex)
        );

        uint256 gasBefore = gasleft();

        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            context,
            actualGasCost,
            actualUserOpFeePerGas
        );

        uint256 gasAfter = gasleft();
        uint256 postOpExecutionCost = gasBefore - gasAfter;

        console.log("=== PostOp Performance Analysis ===");
        console.log("Execution cost:", postOpExecutionCost, "gas");
        console.log(
            "Allocated constant:",
            Constants.POSTOP_ACTIVATION_GAS_COST,
            "gas"
        );
        console.log(
            "Safety buffer:",
            Constants.POSTOP_ACTIVATION_GAS_COST - postOpExecutionCost,
            "gas"
        );
        console.log(
            "Efficiency: ",
            (postOpExecutionCost * 100) / Constants.POSTOP_ACTIVATION_GAS_COST,
            "%"
        );

        console.log("=== External postOp executed successfully ===");
    }

    function _testFirstActivationVerification(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex
    ) internal {
        _verifyActivationFinancialState(nullifierIndex);
        _verifyActivationCacheState(poolId, sender, nullifierIndex);
        _verifyActivationAvailableGas(poolId, nullifierIndex);
    }

    function _verifyActivationFinancialState(
        uint256 nullifierIndex
    ) internal view {
        uint256 nullifier = getNullifier(nullifierIndex);

        uint256 expectedTotalGasCost = 150000 +
            (Constants.POSTOP_ACTIVATION_GAS_COST * 20 gwei);

        uint256 finalNullifierGasUsage = paymaster.nullifierGasUsage(nullifier);
        assertEq(
            finalNullifierGasUsage,
            expectedTotalGasCost,
            "Nullifier gas usage should equal total gas cost"
        );
    }

    function _verifyActivationCacheState(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex
    ) internal view {
        uint256 nullifier = getNullifier(nullifierIndex);
        bytes32 userStateKey = getUserStateKey(sender, poolId);

        uint256 storedNullifier = paymaster.userNullifiers(userStateKey, 0);
        assertEq(
            storedNullifier,
            nullifier,
            "Nullifier should be stored in slot 0"
        );

        uint256 finalNullifierState = paymaster.userNullifiersStates(
            userStateKey
        );

        uint8 activatedCount = finalNullifierState.getActivatedNullifierCount();
        uint8 activeIndex = finalNullifierState.getActiveNullifierIndex();
        bool hasExhaustedSlot = finalNullifierState
            .getHasAvailableExhaustedSlot();

        assertEq(activatedCount, 1, "Should have 1 activated nullifier");
        assertEq(activeIndex, 0, "Should start consuming from slot 0");
        assertFalse(hasExhaustedSlot, "Should not have exhausted slot");
    }

    function _verifyActivationAvailableGas(
        uint256 poolId,
        uint256 nullifierIndex
    ) internal view {
        uint256 nullifier = getNullifier(nullifierIndex);
        uint256 joiningFee = paymaster.getJoiningFee(poolId);
        uint256 finalNullifierGasUsage = paymaster.nullifierGasUsage(nullifier);

        uint256 availableGas = joiningFee - finalNullifierGasUsage;

        assertGt(
            availableGas,
            0,
            "Should have gas remaining for cached transactions"
        );
        console.log("Remaining gas budget:", availableGas, "wei");
    }
}
