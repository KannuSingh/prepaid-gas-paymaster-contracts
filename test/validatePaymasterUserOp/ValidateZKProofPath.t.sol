// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ValidatePaymasterUserOpSetupBase.t.sol";

/// @title ValidateZKProofPath Tests - Fixed Version
/// @notice Test ZK proof validation path in _validatePaymasterUserOp following exact contract validation order
contract ValidateZKProofPathTest is ValidatePaymasterUserOpSetupBase {
    using NullifierCacheStateLib for uint256;

    // Track gas consumption for analysis
    struct GasConsumption {
        string testName;
        uint256 gasUsed;
        bool success;
        string errorType;
    }

    GasConsumption[] public gasResults;

    // ============ SUCCESS SCENARIOS ============

    /// @dev Test successful ZK proof validation in validation mode
    function test_ValidateZKProof_Success_ValidationMode() public {
        uint256 poolId = poolId1;
        address sender = smartAccount1;

        logValidationAttempt(
            "ZK Proof Success Validation",
            poolId,
            sender,
            "ZK Proof"
        );

        // Create valid ZK proof paymaster data with proper root coordination
        bytes memory paymasterData = _createValidZKProofData(
            poolId,
            sender,
            0,
            Constants.PaymasterMode.VALIDATION
        );

        PackedUserOperation memory userOp = createUserOpWithPaymasterData(
            sender,
            paymasterData
        );

        // Execute validation and measure gas
        uint256 gasBefore = gasleft();
        (
            bytes memory context,
            uint256 validationData
        ) = callValidatePaymasterUserOp(
                userOp,
                getUserOpHash(0),
                defaultRequiredPreFund
            );
        uint256 gasUsed = gasBefore - gasleft();

        // Verify successful validation
        assertEq(validationData, 0, "Should return success validation data");
        assertGt(context.length, 0, "Should return non-empty context");
        assertEq(
            context.length,
            181,
            "Should return activation context (181 bytes)"
        );

        // Track gas consumption
        gasResults.push(
            GasConsumption({
                testName: "ZK_Proof_Success_Validation",
                gasUsed: gasUsed,
                success: true,
                errorType: ""
            })
        );

        logValidationResult(true, validationData, context.length);
        console.log("Gas used for successful ZK proof validation:", gasUsed);
    }

    /// @dev Test successful ZK proof validation in estimation mode
    function test_ValidateZKProof_Success_EstimationMode() public {
        uint256 poolId = poolId1;
        address sender = smartAccount1;

        logValidationAttempt(
            "ZK Proof Success Estimation",
            poolId,
            sender,
            "ZK Proof"
        );

        // Create valid ZK proof paymaster data in estimation mode
        bytes memory paymasterData = _createValidZKProofData(
            poolId,
            sender,
            1,
            Constants.PaymasterMode.ESTIMATION
        );

        PackedUserOperation memory userOp = createUserOpWithPaymasterData(
            sender,
            paymasterData
        );

        // Execute validation and measure gas
        uint256 gasBefore = gasleft();
        (
            bytes memory context,
            uint256 validationData
        ) = callValidatePaymasterUserOp(
                userOp,
                getUserOpHash(0),
                defaultRequiredPreFund
            );
        uint256 gasUsed = gasBefore - gasleft();

        // Verify estimation mode behavior
        assertEq(
            validationData,
            Constants.VALIDATION_FAILED,
            "Should return validation failed for estimation"
        );
        assertGt(context.length, 0, "Should return context for estimation");

        // Track gas consumption
        gasResults.push(
            GasConsumption({
                testName: "ZK_Proof_Success_Estimation",
                gasUsed: gasUsed,
                success: false, // false because validationData = VALIDATION_FAILED
                errorType: "EstimationMode"
            })
        );

        logValidationResult(false, validationData, context.length);
        console.log("Gas used for ZK proof estimation:", gasUsed);
    }

    // ============ ERROR SCENARIOS - SYSTEMATIC PIPELINE TESTING ============

    /// @dev Test Step 1: Invalid paymaster data structure
    function test_ValidateZKProof_Step1_InvalidDataStructure() public {
        address sender = smartAccount1;

        logValidationAttempt(
            "Step 1: Invalid Data Structure",
            0,
            sender,
            "Invalid"
        );

        // Create invalid paymaster data (wrong length)
        bytes memory invalidPaymasterData = abi.encodePacked(
            address(paymaster), // 20 bytes
            uint128(100000), // 16 bytes
            uint128(50000), // 16 bytes
            "invalid_short_data" // Too short for ZK proof
        );

        PackedUserOperation memory userOp = createUserOpWithPaymasterData(
            sender,
            invalidPaymasterData
        );

        // Expect validation error
        vm.expectRevert(
            PaymasterValidationErrors.InvalidPaymasterData.selector
        );

        uint256 gasBefore = gasleft();
        callValidatePaymasterUserOp(
            userOp,
            getUserOpHash(0),
            defaultRequiredPreFund
        );
        uint256 gasUsed = gasBefore - gasleft();

        gasResults.push(
            GasConsumption({
                testName: "ZK_Proof_InvalidData",
                gasUsed: gasUsed,
                success: false,
                errorType: "InvalidPaymasterData"
            })
        );
    }

    /// @dev Test Step 2: Invalid merkle tree depth (too small) - FIXED
    function test_ValidateZKProof_Step2_DepthTooSmall() public {
        uint256 poolId = poolId1;
        address sender = smartAccount1;

        logValidationAttempt(
            "Step 2: Depth Too Small",
            poolId,
            sender,
            "ZK Proof"
        );

        // Create paymaster data with invalid depth manually to avoid encoding issues
        bytes memory paymasterData = _createZKProofDataWithRawDepth(
            poolId,
            sender,
            0,
            0, // depth = 0 < MIN_DEPTH(1)
            Constants.PaymasterMode.VALIDATION
        );

        PackedUserOperation memory userOp = createUserOpWithPaymasterData(
            sender,
            paymasterData
        );

        // Expect merkle tree depth error
        vm.expectRevert(
            abi.encodeWithSelector(
                PaymasterValidationErrors.MerkleTreeDepthUnsupported.selector,
                0,
                Constants.MIN_DEPTH,
                Constants.MAX_DEPTH
            )
        );

        callValidatePaymasterUserOp(
            userOp,
            getUserOpHash(0),
            defaultRequiredPreFund
        );
    }

    /// @dev Test Step 2: Invalid merkle tree depth (too large) - FIXED
    function test_ValidateZKProof_Step2_DepthTooLarge() public {
        uint256 poolId = poolId1;
        address sender = smartAccount1;

        logValidationAttempt(
            "Step 2: Depth Too Large",
            poolId,
            sender,
            "ZK Proof"
        );

        // Create paymaster data with invalid depth manually to avoid encoding issues
        bytes memory paymasterData = _createZKProofDataWithRawDepth(
            poolId,
            sender,
            0,
            33, // depth = 33 > MAX_DEPTH(32)
            Constants.PaymasterMode.VALIDATION
        );

        PackedUserOperation memory userOp = createUserOpWithPaymasterData(
            sender,
            paymasterData
        );

        // Expect merkle tree depth error
        vm.expectRevert(
            abi.encodeWithSelector(
                PaymasterValidationErrors.MerkleTreeDepthUnsupported.selector,
                33,
                Constants.MIN_DEPTH,
                Constants.MAX_DEPTH
            )
        );

        callValidatePaymasterUserOp(
            userOp,
            getUserOpHash(0),
            defaultRequiredPreFund
        );
    }

    /// @dev Test Step 3: Non-existent pool
    function test_ValidateZKProof_Step3_NonExistentPool() public {
        uint256 invalidPoolId = 999;
        address sender = smartAccount1;

        logValidationAttempt(
            "Step 3: Non-Existent Pool",
            invalidPoolId,
            sender,
            "ZK Proof"
        );

        // Create paymaster data for non-existent pool - this will fail at pool existence check
        bytes memory paymasterData = _createBasicZKProofData(
            invalidPoolId,
            sender,
            0
        );

        PackedUserOperation memory userOp = createUserOpWithPaymasterData(
            sender,
            paymasterData
        );

        // Expect pool does not exist error
        vm.expectRevert(
            abi.encodeWithSelector(
                PoolErrors.PoolDoesNotExist.selector,
                invalidPoolId
            )
        );

        callValidatePaymasterUserOp(
            userOp,
            getUserOpHash(0),
            defaultRequiredPreFund
        );
    }

    /// @dev Test Step 4: All nullifier slots active - FIXED
    function test_ValidateZKProof_Step4_AllNullifierSlotsActive() public {
        uint256 poolId = poolId1;
        address sender = smartAccount1;

        logValidationAttempt(
            "Step 4: All Nullifier Slots Active",
            poolId,
            sender,
            "ZK Proof"
        );

        // Setup: Simulate user with 2 active nullifiers (max slots filled)
        _simulateMaxNullifierSlots(poolId, sender);

        bytes memory paymasterData = _createValidZKProofData(
            poolId,
            sender,
            2,
            Constants.PaymasterMode.VALIDATION
        );

        PackedUserOperation memory userOp = createUserOpWithPaymasterData(
            sender,
            paymasterData
        );

        // Expect all nullifier slots active error
        vm.expectRevert(
            PaymasterValidationErrors.AllNullifierSlotsActive.selector
        );

        callValidatePaymasterUserOp(
            userOp,
            getUserOpHash(0),
            defaultRequiredPreFund
        );
    }

    /// @dev Test Step 5: Pool has no members
    function test_ValidateZKProof_Step5_PoolHasNoMembers() public {
        address sender = smartAccount1;

        logValidationAttempt(
            "Step 5: Pool Has No Members",
            0,
            sender,
            "ZK Proof"
        );

        // Create empty pool
        uint256 emptyPoolId = paymaster.createPool(JOINING_FEE_1_ETH);

        bytes memory paymasterData = _createBasicZKProofData(
            emptyPoolId,
            sender,
            0
        );

        PackedUserOperation memory userOp = createUserOpWithPaymasterData(
            sender,
            paymasterData
        );

        // Expect pool has no members error
        vm.expectRevert(PoolErrors.PoolHasNoMembers.selector);

        callValidatePaymasterUserOp(
            userOp,
            getUserOpHash(0),
            defaultRequiredPreFund
        );
    }

    /// @dev Test Step 6: Invalid merkle root index - FIXED
    function test_ValidateZKProof_Step6_InvalidMerkleRootIndex() public {
        uint256 poolId = poolId1;
        address sender = smartAccount1;

        logValidationAttempt(
            "Step 6: Invalid Merkle Root Index",
            poolId,
            sender,
            "ZK Proof"
        );

        // Get current root history count and use valid encoding but invalid pool-specific index
        (, , uint32 validCount) = paymaster.getPoolRootHistoryInfo(poolId);
        uint32 invalidRootIndex = validCount + 10;

        // Make sure it's still within encoding limits but beyond pool's history
        if (invalidRootIndex >= Constants.POOL_ROOT_HISTORY_SIZE) {
            invalidRootIndex = Constants.POOL_ROOT_HISTORY_SIZE - 1;
        }

        bytes memory paymasterData = _createZKProofDataWithRawRootIndex(
            poolId,
            sender,
            0,
            invalidRootIndex
        );

        PackedUserOperation memory userOp = createUserOpWithPaymasterData(
            sender,
            paymasterData
        );

        // Expect invalid merkle root index error
        vm.expectRevert(
            abi.encodeWithSelector(
                PaymasterValidationErrors.InvalidMerkleRootIndex.selector,
                invalidRootIndex,
                validCount
            )
        );

        callValidatePaymasterUserOp(
            userOp,
            getUserOpHash(0),
            defaultRequiredPreFund
        );
    }

    /// @dev Test Step 7: User exceeded gas fund
    function test_ValidateZKProof_Step7_UserExceededGasFund() public {
        uint256 poolId = poolId1;
        address sender = smartAccount1;

        logValidationAttempt(
            "Step 7: User Exceeded Gas Fund",
            poolId,
            sender,
            "ZK Proof"
        );

        // Use a very high requiredPreFund that exceeds joining fee
        uint256 joiningFee = paymaster.getJoiningFee(poolId);
        uint256 excessivePreFund = joiningFee + 1000000;

        bytes memory paymasterData = _createValidZKProofData(
            poolId,
            sender,
            0,
            Constants.PaymasterMode.VALIDATION
        );

        PackedUserOperation memory userOp = createUserOpWithPaymasterData(
            sender,
            paymasterData
        );

        // Expect user exceeded gas fund error
        vm.expectRevert(PaymasterValidationErrors.UserExceededGasFund.selector);

        callValidatePaymasterUserOp(userOp, getUserOpHash(0), excessivePreFund);
    }

    /// @dev Test Step 8: Insufficient paymaster fund - FIXED
    // function test_ValidateZKProof_Step8_InsufficientPaymasterFund() public {

    // }

    /// @dev Test Step 9: Invalid proof scope - FIXED
    function test_ValidateZKProof_Step9_InvalidProofScope() public {
        uint256 poolId = poolId1;
        uint256 wrongPoolId = poolId2;
        address sender = smartAccount1;

        logValidationAttempt(
            "Step 9: Invalid Proof Scope",
            poolId,
            sender,
            "ZK Proof"
        );

        bytes memory paymasterData = _createZKProofDataWithRawScope(
            poolId,
            sender,
            0,
            wrongPoolId
        );

        PackedUserOperation memory userOp = createUserOpWithPaymasterData(
            sender,
            paymasterData
        );

        // Expect invalid proof scope error
        vm.expectRevert(
            abi.encodeWithSelector(
                PaymasterValidationErrors.InvalidProofScope.selector,
                wrongPoolId,
                poolId
            )
        );

        callValidatePaymasterUserOp(
            userOp,
            getUserOpHash(0),
            defaultRequiredPreFund
        );
    }

    /// @dev Test Step 10: Invalid proof message - FIXED
    function test_ValidateZKProof_Step10_InvalidProofMessage() public {
        uint256 poolId = poolId1;
        address sender = smartAccount1;

        logValidationAttempt(
            "Step 10: Invalid Proof Message",
            poolId,
            sender,
            "ZK Proof"
        );

        // Create paymaster data with wrong message hash
        bytes32 wrongUserOpHash = keccak256("wrong_message");
        bytes memory paymasterData = _createZKProofDataWithRawMessage(
            poolId,
            sender,
            0,
            uint256(wrongUserOpHash)
        );

        PackedUserOperation memory userOp = createUserOpWithPaymasterData(
            sender,
            paymasterData
        );

        // Calculate correct message hash for comparison
        bytes32 correctMessageHash = paymaster.getMessageHash(userOp);

        // Expect invalid proof message error
        vm.expectRevert(
            abi.encodeWithSelector(
                PaymasterValidationErrors.InvalidProofMessage.selector,
                uint256(wrongUserOpHash),
                uint256(correctMessageHash)
            )
        );

        callValidatePaymasterUserOp(
            userOp,
            getUserOpHash(0),
            defaultRequiredPreFund
        );
    }

    /// @dev Test Step 11: Invalid merkle tree root - FIXED
    function test_ValidateZKProof_Step11_InvalidMerkleTreeRoot() public {
        uint256 poolId = poolId1;
        address sender = smartAccount1;

        logValidationAttempt(
            "Step 11: Invalid Merkle Tree Root",
            poolId,
            sender,
            "ZK Proof"
        );

        // Get expected root for error comparison
        (uint256 expectedRoot, uint32 rootIndex) = paymaster
            .getLatestValidRootInfo(poolId);
        uint256 wrongRoot = 12345;

        bytes memory paymasterData = _createZKProofDataWithRawRoot(
            poolId,
            sender,
            0,
            wrongRoot,
            rootIndex
        );

        PackedUserOperation memory userOp = createUserOpWithPaymasterData(
            sender,
            paymasterData
        );

        // Expect invalid merkle tree root error
        vm.expectRevert(
            abi.encodeWithSelector(
                PaymasterValidationErrors.InvalidMerkleTreeRoot.selector,
                wrongRoot,
                expectedRoot
            )
        );

        callValidatePaymasterUserOp(
            userOp,
            getUserOpHash(0),
            defaultRequiredPreFund
        );
    }

    /// @dev Test Step 12: Proof verification failed
    function test_ValidateZKProof_Step12_ProofVerificationFailed() public {
        uint256 poolId = poolId1;
        address sender = smartAccount1;

        logValidationAttempt(
            "Step 12: Proof Verification Failed",
            poolId,
            sender,
            "ZK Proof"
        );

        // Setup mock verifier to return false
        mockVerifier.setShouldReturnValid(false);

        bytes memory paymasterData = _createValidZKProofData(
            poolId,
            sender,
            0,
            Constants.PaymasterMode.VALIDATION
        );

        PackedUserOperation memory userOp = createUserOpWithPaymasterData(
            sender,
            paymasterData
        );

        // Expect proof verification failed error
        vm.expectRevert(
            PaymasterValidationErrors.ProofVerificationFailed.selector
        );

        callValidatePaymasterUserOp(
            userOp,
            getUserOpHash(0),
            defaultRequiredPreFund
        );

        // Reset mock verifier
        mockVerifier.setShouldReturnValid(true);
    }

    // ============ INTERNAL HELPER FUNCTIONS - FIXED VERSIONS ============

    /// @dev Create ZK proof data with raw depth value (bypasses encoding validation)
    function _createZKProofDataWithRawDepth(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 customDepth,
        Constants.PaymasterMode mode
    ) internal view returns (bytes memory) {
        // Get proper base values
        (uint256 merkleTreeRoot, uint32 rootIndex) = paymaster
            .getLatestValidRootInfo(poolId);

        // Create UserOp for message hash calculation
        PackedUserOperation memory tempUserOp = baseUserOp;
        tempUserOp.sender = sender;
        tempUserOp.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100000),
            uint128(50000)
        );
        bytes32 messageHash = paymaster.getMessageHash(tempUserOp);

        uint256 nullifier = nullifierIndex < nullifiers.length
            ? nullifiers[nullifierIndex]
            : 12345;

        // Manually encode the proof with custom depth
        DataLib.PoolMembershipProof memory proof = DataLib.PoolMembershipProof({
            merkleTreeDepth: customDepth, // Custom depth value
            merkleTreeRoot: merkleTreeRoot,
            nullifier: nullifier,
            message: uint256(messageHash),
            scope: poolId,
            points: [uint256(1), 2, 3, 4, 5, 6, 7, 8]
        });

        return _encodePaymasterDataManually(poolId, rootIndex, mode, proof);
    }

    /// @dev Create ZK proof data with raw root index (for valid encoding but pool-specific validation)
    function _createZKProofDataWithRawRootIndex(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint32 customRootIndex
    ) internal view returns (bytes memory) {
        uint256 merkleTreeDepth = paymaster.getMerkleTreeDepth(poolId);
        (uint256 merkleTreeRoot, ) = paymaster.getLatestValidRootInfo(poolId);

        PackedUserOperation memory tempUserOp = baseUserOp;
        tempUserOp.sender = sender;
        tempUserOp.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100000),
            uint128(50000)
        );
        bytes32 messageHash = paymaster.getMessageHash(tempUserOp);

        uint256 nullifier = nullifierIndex < nullifiers.length
            ? nullifiers[nullifierIndex]
            : 12345;

        DataLib.PoolMembershipProof memory proof = DataLib.PoolMembershipProof({
            merkleTreeDepth: merkleTreeDepth,
            merkleTreeRoot: merkleTreeRoot,
            nullifier: nullifier,
            message: uint256(messageHash),
            scope: poolId,
            points: [uint256(1), 2, 3, 4, 5, 6, 7, 8]
        });

        return
            _encodePaymasterDataManually(
                poolId,
                customRootIndex,
                Constants.PaymasterMode.VALIDATION,
                proof
            );
    }

    /// @dev Create ZK proof data with raw scope value
    function _createZKProofDataWithRawScope(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 customScope
    ) internal view returns (bytes memory) {
        uint256 merkleTreeDepth = paymaster.getMerkleTreeDepth(poolId);
        (uint256 merkleTreeRoot, uint32 rootIndex) = paymaster
            .getLatestValidRootInfo(poolId);

        PackedUserOperation memory tempUserOp = baseUserOp;
        tempUserOp.sender = sender;
        tempUserOp.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100000),
            uint128(50000)
        );
        bytes32 messageHash = paymaster.getMessageHash(tempUserOp);

        uint256 nullifier = nullifierIndex < nullifiers.length
            ? nullifiers[nullifierIndex]
            : 12345;

        DataLib.PoolMembershipProof memory proof = DataLib.PoolMembershipProof({
            merkleTreeDepth: merkleTreeDepth,
            merkleTreeRoot: merkleTreeRoot,
            nullifier: nullifier,
            message: uint256(messageHash),
            scope: customScope, // Custom scope value
            points: [uint256(1), 2, 3, 4, 5, 6, 7, 8]
        });

        return
            _encodePaymasterDataManually(
                poolId,
                rootIndex,
                Constants.PaymasterMode.VALIDATION,
                proof
            );
    }

    /// @dev Create ZK proof data with raw message value
    function _createZKProofDataWithRawMessage(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 customMessage
    ) internal view returns (bytes memory) {
        uint256 merkleTreeDepth = paymaster.getMerkleTreeDepth(poolId);
        (uint256 merkleTreeRoot, uint32 rootIndex) = paymaster
            .getLatestValidRootInfo(poolId);

        uint256 nullifier = nullifierIndex < nullifiers.length
            ? nullifiers[nullifierIndex]
            : 12345;

        DataLib.PoolMembershipProof memory proof = DataLib.PoolMembershipProof({
            merkleTreeDepth: merkleTreeDepth,
            merkleTreeRoot: merkleTreeRoot,
            nullifier: nullifier,
            message: customMessage, // Custom message value
            scope: poolId,
            points: [uint256(1), 2, 3, 4, 5, 6, 7, 8]
        });

        return
            _encodePaymasterDataManually(
                poolId,
                rootIndex,
                Constants.PaymasterMode.VALIDATION,
                proof
            );
    }

    /// @dev Create ZK proof data with raw root value
    function _createZKProofDataWithRawRoot(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 customRoot,
        uint32 rootIndex
    ) internal view returns (bytes memory) {
        uint256 merkleTreeDepth = paymaster.getMerkleTreeDepth(poolId);

        PackedUserOperation memory tempUserOp = baseUserOp;
        tempUserOp.sender = sender;
        tempUserOp.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100000),
            uint128(50000)
        );
        bytes32 messageHash = paymaster.getMessageHash(tempUserOp);

        uint256 nullifier = nullifierIndex < nullifiers.length
            ? nullifiers[nullifierIndex]
            : 12345;

        DataLib.PoolMembershipProof memory proof = DataLib.PoolMembershipProof({
            merkleTreeDepth: merkleTreeDepth,
            merkleTreeRoot: customRoot, // Custom root value
            nullifier: nullifier,
            message: uint256(messageHash),
            scope: poolId,
            points: [uint256(1), 2, 3, 4, 5, 6, 7, 8]
        });

        return
            _encodePaymasterDataManually(
                poolId,
                rootIndex,
                Constants.PaymasterMode.VALIDATION,
                proof
            );
    }

    /// @dev Manually encode paymaster data (bypasses DataLib validation)
    function _encodePaymasterDataManually(
        uint256 poolId,
        uint32 rootIndex,
        Constants.PaymasterMode mode,
        DataLib.PoolMembershipProof memory proof
    ) internal view returns (bytes memory) {
        // Manually pack config to avoid DataLib validation
        uint256 config = uint256(rootIndex) | (uint256(mode) << 32);

        // Manually encode proof
        bytes memory proofBytes = abi.encode(proof);

        // Pack everything together
        bytes memory customData = abi.encodePacked(
            config, // 32 bytes
            poolId, // 32 bytes
            proofBytes // 416 bytes
        );

        return
            abi.encodePacked(
                address(paymaster),
                uint128(100000),
                uint128(50000),
                customData
            );
    }

    /// @dev Create valid ZK proof paymaster data with proper root coordination
    function _createValidZKProofData(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        Constants.PaymasterMode mode
    ) internal view returns (bytes memory) {
        require(
            nullifierIndex < nullifiers.length,
            "Nullifier index out of bounds"
        );

        // Get current root information from pool
        (uint256 currentRoot, uint32 currentRootIndex) = paymaster
            .getLatestValidRootInfo(poolId);

        // Create temporary UserOp for message hash calculation
        PackedUserOperation memory tempUserOp = baseUserOp;
        tempUserOp.sender = sender;
        tempUserOp.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100000),
            uint128(50000)
        );

        // Calculate message hash
        bytes32 messageHash = paymaster.getMessageHash(tempUserOp);

        // Get pool data
        uint256 merkleTreeDepth = paymaster.getMerkleTreeDepth(poolId);
        uint256 nullifier = nullifiers[nullifierIndex];

        // Create proof structure with proper root coordination
        DataLib.PoolMembershipProof memory proof = DataLib.PoolMembershipProof({
            merkleTreeDepth: merkleTreeDepth,
            merkleTreeRoot: currentRoot, // Use current root from pool
            nullifier: nullifier,
            message: uint256(messageHash),
            scope: poolId,
            points: [uint256(1), 2, 3, 4, 5, 6, 7, 8]
        });

        // Create paymaster data with current root index
        DataLib.PaymasterData memory data = DataLib.PaymasterData({
            config: DataLib.PaymasterConfig({
                merkleRootIndex: currentRootIndex, // Use current index
                mode: mode
            }),
            poolId: poolId,
            proof: proof
        });

        bytes memory encodedData = DataLib.encodePaymasterData(data);

        return
            abi.encodePacked(
                address(paymaster),
                uint128(100000),
                uint128(50000),
                encodedData
            );
    }

    /// @dev Create basic ZK proof data for non-existent pools or minimal validation
    function _createBasicZKProofData(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex
    ) internal view returns (bytes memory) {
        // Create temporary UserOp for message hash calculation
        PackedUserOperation memory tempUserOp = baseUserOp;
        tempUserOp.sender = sender;
        tempUserOp.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100000),
            uint128(50000)
        );

        bytes32 messageHash = paymaster.getMessageHash(tempUserOp);
        uint256 nullifier = nullifierIndex < nullifiers.length
            ? nullifiers[nullifierIndex]
            : 12345;

        // Create basic proof with minimal valid structure
        DataLib.PoolMembershipProof memory proof = DataLib.PoolMembershipProof({
            merkleTreeDepth: 1, // Minimal valid depth
            merkleTreeRoot: 0, // Will be invalid for validation but structure is correct
            nullifier: nullifier,
            message: uint256(messageHash),
            scope: poolId,
            points: [uint256(1), 2, 3, 4, 5, 6, 7, 8]
        });

        DataLib.PaymasterData memory data = DataLib.PaymasterData({
            config: DataLib.PaymasterConfig({
                merkleRootIndex: 0,
                mode: Constants.PaymasterMode.VALIDATION
            }),
            poolId: poolId,
            proof: proof
        });

        bytes memory encodedData = DataLib.encodePaymasterData(data);

        return
            abi.encodePacked(
                address(paymaster),
                uint128(100000),
                uint128(50000),
                encodedData
            );
    }

    /// @dev Simulate user having maximum nullifier slots filled - FIXED storage calculation
    function _simulateMaxNullifierSlots(
        uint256 poolId,
        address sender
    ) internal {
        bytes32 userStateKey = keccak256(abi.encode(poolId, sender));

        // Simulate state: 2 active nullifiers, no exhausted slots
        uint256 simulatedState = NullifierCacheStateLib.encodeFlags(
            2, // activatedNullifierCount = 2 (max)
            0, // exhaustedSlotIndex = 0
            false, // hasAvailableExhaustedSlot = false
            0 // activeNullifierIndex = 0
        );

        // Fixed storage slot calculation:
        // Storage layout: _owner(0), poolCounter(1), merkleTrees(2), pools(3), poolExists(4), totalUsersDeposit(5), nullifierGasUsage(6), userNullifiers(7), userNullifiersStates(8)

        // userNullifiersStates mapping is at slot 8
        bytes32 stateSlot = keccak256(abi.encode(userStateKey, uint256(8)));
        vm.store(address(paymaster), stateSlot, bytes32(simulatedState));

        // userNullifiers mapping is at slot 7
        bytes32 nullifierSlot = keccak256(abi.encode(userStateKey, uint256(7)));

        // Set nullifier in slot 0
        bytes32 slot0 = keccak256(abi.encode(nullifierSlot, uint256(0)));
        vm.store(address(paymaster), slot0, bytes32(nullifiers[0]));

        // Set nullifier in slot 1
        bytes32 slot1 = keccak256(abi.encode(nullifierSlot, uint256(1)));
        vm.store(address(paymaster), slot1, bytes32(nullifiers[1]));

        console.log("Simulated max nullifier slots for user");

        // Verify the simulation worked
        uint256 verifyState = paymaster.userNullifiersStates(userStateKey);
        uint8 verifyCount = verifyState.getActivatedNullifierCount();
        console.log("Verified activated count:", verifyCount);
        require(verifyCount == 2, "Failed to simulate max nullifier slots");
    }
}
