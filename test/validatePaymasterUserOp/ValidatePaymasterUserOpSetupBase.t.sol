// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../contracts/SimpleCacheGasLimitedPaymaster.sol";
import "../../contracts/interfaces/IPoolManager.sol";
import "../../contracts/base/DataLib.sol";
import "../../contracts/base/Constants.sol";
import "../../contracts/base/NullifierCacheStateLib.sol";
import "../../contracts/errors/PaymasterValidationErrors.sol";
import "../../contracts/errors/PoolErrors.sol";
import "../mocks/MockContracts.sol";
import "@account-abstraction/contracts/core/UserOperationLib.sol";

/// @title ValidatePaymasterUserOpSetupBase - Fixed Version
/// @notice Base setup for testing _validatePaymasterUserOp method with proper message hash handling
abstract contract ValidatePaymasterUserOpSetupBase is Test {
    using UserOperationLib for PackedUserOperation;
    using NullifierCacheStateLib for uint256;

    // ============ Contract Instances ============
    SimpleCacheEnabledGasLimitedPaymaster public paymaster;
    MockPoolMembershipProofVerifier public mockVerifier;
    MockEntryPoint public mockEntryPoint;

    // ============ Test Addresses ============
    address public owner;
    address public user1;
    address public user2;
    address public smartAccount1;
    address public smartAccount2;

    // ============ Pool Configuration ============
    uint256 public poolId1;
    uint256 public poolId2;
    uint256 public poolId3;

    uint256 public constant JOINING_FEE_1_ETH = TestUtils.JOINING_FEE_1_ETH;
    uint256 public constant JOINING_FEE_0_1_ETH = TestUtils.JOINING_FEE_0_1_ETH;
    uint256 public constant JOINING_FEE_5_ETH = TestUtils.JOINING_FEE_5_ETH;

    // ============ Test Data ============
    uint256[] public identities;
    uint256[] public nullifiers;
    bytes32[] public userOpHashes;

    // ============ Sample UserOp Data ============
    PackedUserOperation public baseUserOp;
    bytes32 public sampleUserOpHash;
    uint256 public defaultRequiredPreFund;

    function setUp() public virtual {
        _initializeAddresses();
        _deployContracts();
        _fundAccounts();
        _createPools();
        _generateTestData();
        _addMembersToTestPools();
        _initializeUserOp();
        _verifySetupState();

        console.log("ValidatePaymasterUserOp setup completed successfully");
    }

    // ============ Setup Helper Functions ============

    function _initializeAddresses() internal {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        smartAccount1 = makeAddr("smartAccount1");
        smartAccount2 = makeAddr("smartAccount2");
    }

    function _deployContracts() internal {
        mockVerifier = new MockPoolMembershipProofVerifier();
        mockEntryPoint = new MockEntryPoint();
        mockVerifier.setShouldReturnValid(true);

        paymaster = new SimpleCacheEnabledGasLimitedPaymaster(
            address(mockEntryPoint),
            address(mockVerifier)
        );
    }

    function _fundAccounts() internal {
        vm.deal(address(this), 200 ether);
        vm.deal(user1, 50 ether);
        vm.deal(user2, 50 ether);

        // Fund paymaster in EntryPoint for operations
        mockEntryPoint.depositTo{value: 100 ether}(address(paymaster));
    }

    function _createPools() internal {
        poolId1 = paymaster.createPool(JOINING_FEE_1_ETH);
        poolId2 = paymaster.createPool(JOINING_FEE_0_1_ETH);
        poolId3 = paymaster.createPool(JOINING_FEE_5_ETH);
    }

    function _generateTestData() internal {
        // Generate identities
        for (uint256 i = 1; i <= 20; i++) {
            uint256 identity = TestUtils.generateIdentity(
                string(abi.encodePacked("validate_test_", i))
            );
            identities.push(identity);
        }

        // Generate nullifiers
        for (uint256 i = 1; i <= 20; i++) {
            uint256 nullifier = uint256(
                keccak256(
                    abi.encodePacked("validate_nullifier_", i, block.number)
                )
            ) % TestUtils.SNARK_SCALAR_FIELD;
            nullifiers.push(nullifier);
        }

        // Generate UserOp hashes
        for (uint256 i = 1; i <= 10; i++) {
            bytes32 hash = keccak256(
                abi.encodePacked("validate_userOp_", i, block.timestamp)
            );
            userOpHashes.push(hash);
        }

        // Set sample hash
        sampleUserOpHash = userOpHashes[0];
    }

    function _addMembersToTestPools() internal {
        // Add members to pools
        for (uint256 i = 0; i < 5; i++) {
            paymaster.addMember{value: JOINING_FEE_1_ETH}(
                poolId1,
                identities[i]
            );
        }

        for (uint256 i = 5; i < 8; i++) {
            paymaster.addMember{value: JOINING_FEE_0_1_ETH}(
                poolId2,
                identities[i]
            );
        }

        for (uint256 i = 8; i < 10; i++) {
            paymaster.addMember{value: JOINING_FEE_5_ETH}(
                poolId3,
                identities[i]
            );
        }
    }

    function _initializeUserOp() internal {
        // Create base UserOp matching the TypeScript script pattern
        baseUserOp = PackedUserOperation({
            sender: smartAccount1,
            nonce: 1,
            initCode: "",
            callData: abi.encodeWithSignature(
                "execute(address,uint256,bytes)",
                makeAddr("target"), // Similar to TS script's target
                0,
                hex"deadbeef" // Similar to TS script's data
            ),
            accountGasLimits: bytes32(
                (uint256(200000) << 128) | uint256(200000) // verificationGasLimit | callGasLimit
            ),
            preVerificationGas: 50000,
            gasFees: bytes32(
                (uint256(20 gwei) << 128) | uint256(15 gwei) // maxFeePerGas | maxPriorityFeePerGas
            ),
            paymasterAndData: "", // Will be set per test
            signature: hex"1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234" // 65 bytes
        });

        defaultRequiredPreFund = 0.001 ether; // Reasonable default
    }

    function _verifySetupState() internal view {
        assertTrue(paymaster.poolExists(poolId1));
        assertTrue(paymaster.poolExists(poolId2));
        assertTrue(paymaster.poolExists(poolId3));

        assertEq(paymaster.getMerkleTreeSize(poolId1), 5);
        assertEq(paymaster.getMerkleTreeSize(poolId2), 3);
        assertEq(paymaster.getMerkleTreeSize(poolId3), 2);

        assertGt(mockEntryPoint.balanceOf(address(paymaster)), 50 ether);
    }

    // ============ Helper Functions ============

    function getIdentity(uint256 index) public view returns (uint256) {
        require(index < identities.length, "Identity index out of bounds");
        return identities[index];
    }

    function getNullifier(uint256 index) public view returns (uint256) {
        require(index < nullifiers.length, "Nullifier index out of bounds");
        return nullifiers[index];
    }

    function getUserOpHash(uint256 index) public view returns (bytes32) {
        require(index < userOpHashes.length, "UserOp hash index out of bounds");
        return userOpHashes[index];
    }

    // ============ Paymaster Data Creation Helpers - FIXED ============

    /// @dev Create cached paymaster data - CORRECTED format based on contract assembly
    function createCachedPaymasterData(
        uint256 poolId,
        Constants.PaymasterMode mode
    ) public view returns (bytes memory) {
        // Contract expects exactly 85 bytes:
        // - 20 bytes: paymaster address
        // - 16 bytes: paymasterVerificationGasLimit (uint128)
        // - 16 bytes: paymasterPostOpGasLimit (uint128)
        // - 32 bytes: poolId (uint256)
        // - 1 byte: mode (uint8)

        return
            abi.encodePacked(
                address(paymaster), // 20 bytes
                uint128(100000), // paymasterVerificationGasLimit - 16 bytes
                uint128(50000), // paymasterPostOpGasLimit - 16 bytes
                poolId, // 32 bytes - poolId
                uint8(mode) // 1 byte - mode
            ); // Total: 85 bytes
    }

    /// @dev Create UserOp with specific paymaster data and ensure message hash consistency
    function createUserOpWithPaymasterData(
        address sender,
        bytes memory paymasterAndData
    ) public view returns (PackedUserOperation memory userOp) {
        userOp = baseUserOp;
        userOp.sender = sender;
        userOp.paymasterAndData = paymasterAndData;
    }

    /// @dev Get calculated message hash for a UserOp (matching contract logic exactly)
    function getCalculatedMessageHash(
        PackedUserOperation memory userOp
    ) public view returns (bytes32) {
        return paymaster.getMessageHash(userOp);
    }

    /// @dev Create a valid UserOp prefix for message hash calculation (first 52 bytes)
    function createValidUserOpPrefix() public view returns (bytes memory) {
        return
            abi.encodePacked(
                address(paymaster), // 20 bytes
                uint128(100000), // paymasterVerificationGasLimit - 16 bytes
                uint128(50000) // paymasterPostOpGasLimit - 16 bytes
            ); // Total: 52 bytes
    }

    // ============ Validation Helper Functions ============

    /// @dev Call _validatePaymasterUserOp and capture results
    function callValidatePaymasterUserOp(
        PackedUserOperation memory userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    ) public returns (bytes memory context, uint256 validationData) {
        // Call the public validatePaymasterUserOp from BasePaymaster
        vm.prank(address(mockEntryPoint));
        return
            paymaster.validatePaymasterUserOp(
                userOp,
                userOpHash,
                requiredPreFund
            );
    }

    /// @dev Expect specific validation error
    function expectValidationError(bytes4 expectedError) public {
        vm.expectRevert(expectedError);
    }

    /// @dev Expect validation error with parameters
    function expectValidationErrorWithParams(
        bytes memory expectedError
    ) public {
        vm.expectRevert(expectedError);
    }

    // ============ Logging Helpers ============

    /// @dev Log validation attempt details
    function logValidationAttempt(
        string memory testName,
        uint256 poolId,
        address sender,
        string memory paymasterDataType
    ) public view {
        console.log("=== Validation Test:", testName, "===");
        console.log("Pool ID:", poolId);
        console.log("Sender:", sender);
        console.log("Paymaster data type:", paymasterDataType);
        if (paymaster.poolExists(poolId)) {
            console.log("Pool size:", paymaster.getMerkleTreeSize(poolId));
            console.log("Joining fee:", paymaster.getJoiningFee(poolId));

            // Log current root info
            (uint256 currentRoot, uint32 currentRootIndex) = paymaster
                .getLatestValidRootInfo(poolId);
            console.log("Current root:", currentRoot);
            console.log("Current root index:", currentRootIndex);
        } else {
            console.log("Pool does not exist");
        }
    }

    /// @dev Log validation results
    function logValidationResult(
        bool success,
        uint256 validationData,
        uint256 contextLength
    ) public view {
        console.log("--- Validation Result ---");
        console.log("Success:", success);
        console.log("Validation data:", validationData);
        console.log("Context length:", contextLength);
        console.log("------------------------");
    }

    // ============ Additional Debugging Helpers ============

    /// @dev Get pool state for debugging
    function getPoolDebugInfo(
        uint256 poolId
    )
        public
        view
        returns (
            bool exists,
            uint256 size,
            uint256 depth,
            uint256 currentRoot,
            uint32 currentRootIndex,
            uint256 joiningFee
        )
    {
        exists = paymaster.poolExists(poolId);
        if (exists) {
            size = paymaster.getMerkleTreeSize(poolId);
            depth = paymaster.getMerkleTreeDepth(poolId);
            (currentRoot, currentRootIndex) = paymaster.getLatestValidRootInfo(
                poolId
            );
            joiningFee = paymaster.getJoiningFee(poolId);
        }
    }

    /// @dev Debug paymaster financial state
    function debugPaymasterFinances() public view {
        console.log("=== Paymaster Financial State ===");
        console.log("EntryPoint deposit:", paymaster.getDeposit());
        console.log("Total users deposit:", paymaster.totalUsersDeposit());
        console.log("Revenue:", paymaster.getRevenue());
        console.log("Pool 1 deposits:", paymaster.getPoolDeposits(poolId1));
        console.log("Pool 2 deposits:", paymaster.getPoolDeposits(poolId2));
        console.log("Pool 3 deposits:", paymaster.getPoolDeposits(poolId3));
    }

    // ============ Message Hash Debugging ============

    /// @dev Debug message hash calculation step by step
    function debugMessageHashCalculation(
        PackedUserOperation memory userOp
    ) public view {
        console.log("=== Message Hash Debug ===");
        console.log("Sender:", userOp.sender);
        console.log("Nonce:", userOp.nonce);
        console.log("PaymasterAndData length:", userOp.paymasterAndData.length);

        // Show first 52 bytes that are used in hash
        if (userOp.paymasterAndData.length >= 52) {
            console.log("First 52 bytes of paymasterAndData (used in hash):");
            for (
                uint256 i = 0;
                i < 52 && i < userOp.paymasterAndData.length;
                i++
            ) {
                console.log(
                    "  Byte",
                    i,
                    ":",
                    uint8(userOp.paymasterAndData[i])
                );
            }
        }

        bytes32 calculatedHash = paymaster.getMessageHash(userOp);
        console.log("Calculated message hash:", uint256(calculatedHash));
    }
}
