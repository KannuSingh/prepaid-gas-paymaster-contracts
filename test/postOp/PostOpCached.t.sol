// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PostOpSetupBase.t.sol";

/// @title PostOpCached Tests
/// @notice Focused tests for cached consumption flow
contract PostOpCachedTest is PostOpSetupBase {
    using NullifierCacheStateLib for uint256;

    /// @dev Test cached consumption from activated nullifier
    function test_PostOp_CachedConsumption() public {
        uint256 poolId = poolId1;
        address sender = sender1;
        uint256 nullifierIndex = 1;
        uint256 userOpHashIndex = 1;

        console.log("=== Cached Consumption Test ===");
        console.log("Pool ID:", poolId);
        console.log("Sender:", sender);

        _setupActivatedNullifierForCachedTest(
            poolId,
            sender,
            nullifierIndex,
            userOpHashIndex
        );
        _testCachedConsumptionExecution(
            poolId,
            sender,
            nullifierIndex,
            userOpHashIndex
        );
        _testCachedConsumptionVerification(poolId, sender, nullifierIndex);

        console.log("Cached consumption test completed successfully");
    }

    function _setupActivatedNullifierForCachedTest(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 userOpHashIndex
    ) internal {
        console.log("=== Pre-Setup: Activating nullifier for cached test ===");

        bytes memory activationContext = createFirstActivationContext(
            poolId,
            sender,
            nullifierIndex,
            userOpHashIndex
        );

        vm.prank(address(mockEntryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            activationContext,
            100000,
            15 gwei
        );

        bytes32 userStateKey = getUserStateKey(sender, poolId);
        uint256 nullifierState = paymaster.userNullifiersStates(userStateKey);
        uint8 activatedCount = nullifierState.getActivatedNullifierCount();
        assertEq(
            activatedCount,
            1,
            "Should have 1 activated nullifier after setup"
        );

        console.log("Setup complete: 1 nullifier activated");
    }

    function _testCachedConsumptionExecution(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 userOpHashIndex
    ) internal {
        uint256 actualGasCost = 120000;
        uint256 actualUserOpFeePerGas = 25 gwei;

        uint256 expectedPostOpGas = Constants.POSTOP_CACHE_GAS_COST *
            actualUserOpFeePerGas;
        uint256 expectedTotalGasCost = actualGasCost + expectedPostOpGas;

        console.log("Actual gas cost:", actualGasCost);
        console.log("Gas price:", actualUserOpFeePerGas);
        console.log("Expected total cost:", expectedTotalGasCost);

        bytes memory context = createCachedConsumptionContext(
            poolId,
            sender,
            1,
            0,
            userOpHashIndex
        );

        assertEq(context.length, 181, "Context should be 181 bytes");
        assertFalse(isActivationContext(context), "Should be cached context");
        assertEq(
            getPoolIdFromContext(context),
            poolId,
            "Context pool ID should match"
        );

        console.log("=== About to call cached postOp ===");

        vm.expectEmit(true, true, false, false);
        emit UserOpSponsoredCached(
            getUserOpHash(userOpHashIndex),
            poolId,
            sender,
            expectedTotalGasCost,
            0
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

        console.log("=== Cached PostOp Performance Analysis ===");
        console.log("Execution cost:", postOpExecutionCost, "gas");
        console.log(
            "Allocated constant:",
            Constants.POSTOP_CACHE_GAS_COST,
            "gas"
        );
        console.log(
            "Safety buffer:",
            Constants.POSTOP_CACHE_GAS_COST - postOpExecutionCost,
            "gas"
        );
        console.log(
            "Efficiency: ",
            (postOpExecutionCost * 100) / Constants.POSTOP_CACHE_GAS_COST,
            "%"
        );
    }

    function _testCachedConsumptionVerification(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex
    ) internal view {
        uint256 nullifier = getNullifier(nullifierIndex);
        bytes32 userStateKey = getUserStateKey(sender, poolId);

        uint256 finalNullifierGasUsage = paymaster.nullifierGasUsage(nullifier);
        assertGt(
            finalNullifierGasUsage,
            0,
            "Nullifier should have accumulated gas usage"
        );

        uint256 storedNullifier = paymaster.userNullifiers(userStateKey, 0);
        assertEq(
            storedNullifier,
            nullifier,
            "Nullifier should still be in slot 0"
        );

        uint256 finalNullifierState = paymaster.userNullifiersStates(
            userStateKey
        );
        uint8 activatedCount = finalNullifierState.getActivatedNullifierCount();
        assertEq(activatedCount, 1, "Should still have 1 activated nullifier");

        uint256 joiningFee = paymaster.getJoiningFee(poolId);
        uint256 availableGas = joiningFee - finalNullifierGasUsage;

        assertGt(availableGas, 0, "Should still have gas remaining");
        console.log("Remaining gas budget:", availableGas, "wei");
        console.log(
            "Total gas consumed from nullifier:",
            finalNullifierGasUsage,
            "wei"
        );
    }
}
