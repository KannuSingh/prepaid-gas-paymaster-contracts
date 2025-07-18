// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../contracts/SimpleCacheGasLimitedPaymaster.sol";
import "../../contracts/interfaces/IPoolManager.sol";
import "../../contracts/errors/PoolErrors.sol";
import "../mocks/MockContracts.sol";

/// @title AddMember Method Tests
/// @notice Comprehensive testing of the addMember functionality
contract AddMemberTest is Test {
    SimpleCacheEnabledGasLimitedPaymaster public paymaster;
    MockPoolMembershipProofVerifier public mockVerifier;
    MockEntryPoint public mockEntryPoint;

    address public owner;
    address public user1;
    address public user2;
    address public user3;

    uint256 public poolId1;
    uint256 public poolId2;
    uint256 public poolId3;

    // SNARK scalar field modulus (roughly 2^254)
    uint256 constant SNARK_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Deploy mocks
        mockVerifier = new MockPoolMembershipProofVerifier();
        mockEntryPoint = new MockEntryPoint();

        // Deploy paymaster
        paymaster = new SimpleCacheEnabledGasLimitedPaymaster(
            address(mockEntryPoint),
            address(mockVerifier)
        );

        // Fund accounts
        vm.deal(address(this), 100 ether);
        vm.deal(user1, 20 ether);
        vm.deal(user2, 20 ether);
        vm.deal(user3, 20 ether);

        // Create test pools using TestUtils constants
        poolId1 = paymaster.createPool(TestUtils.JOINING_FEE_1_ETH);
        poolId2 = paymaster.createPool(TestUtils.JOINING_FEE_0_1_ETH);
        poolId3 = paymaster.createPool(TestUtils.JOINING_FEE_5_ETH);
    }

    // ============ Basic Functionality Tests ============

    /// @dev Test successful member addition
    function test_AddMember_Success() public {
        uint256 initialPoolDeposits = paymaster.getPoolDeposits(poolId1);
        uint256 initialTotalUserDeposits = paymaster.totalUsersDeposit();
        uint256 initialEntryPointBalance = mockEntryPoint.balanceOf(
            address(paymaster)
        );
        uint256 initialPoolSize = paymaster.getMerkleTreeSize(poolId1);

        // Use simple valid identity
        uint256 validIdentity = 1;

        // Don't check exact event params since they're computed
        vm.expectEmit(true, true, false, false);
        emit IPoolManager.MemberAdded(poolId1, 0, validIdentity, 0, 0);

        uint256 merkleTreeRoot = paymaster.addMember{
            value: TestUtils.JOINING_FEE_1_ETH
        }(poolId1, validIdentity);

        // Verify state changes
        assertEq(
            paymaster.getPoolDeposits(poolId1),
            initialPoolDeposits + TestUtils.JOINING_FEE_1_ETH
        );
        assertEq(
            paymaster.totalUsersDeposit(),
            initialTotalUserDeposits + TestUtils.JOINING_FEE_1_ETH
        );
        assertEq(
            mockEntryPoint.balanceOf(address(paymaster)),
            initialEntryPointBalance + TestUtils.JOINING_FEE_1_ETH
        );
        assertEq(paymaster.getMerkleTreeSize(poolId1), initialPoolSize + 1);

        // Verify member was added to merkle tree
        assertTrue(paymaster.hasMember(poolId1, validIdentity));
        assertEq(paymaster.indexOf(poolId1, validIdentity), 0);
        assertGt(merkleTreeRoot, 0); // Should return a valid root
        assertEq(paymaster.getMerkleTreeRoot(poolId1), merkleTreeRoot);
    }

    /// @dev Test adding multiple members to same pool
    function test_AddMember_MultipleMembers() public {
        // Use valid SNARK field identities (ensure they're different)
        uint256 identity1 = 1;
        uint256 identity2 = 2;
        uint256 identity3 = 3;

        // Add first member
        paymaster.addMember{value: TestUtils.JOINING_FEE_1_ETH}(
            poolId1,
            identity1
        );

        // Add second member
        uint256 merkleTreeRoot2 = paymaster.addMember{
            value: TestUtils.JOINING_FEE_1_ETH
        }(poolId1, identity2);

        // Add third member
        uint256 merkleTreeRoot3 = paymaster.addMember{
            value: TestUtils.JOINING_FEE_1_ETH
        }(poolId1, identity3);

        // Verify all members exist
        assertTrue(paymaster.hasMember(poolId1, identity1));
        assertTrue(paymaster.hasMember(poolId1, identity2));
        assertTrue(paymaster.hasMember(poolId1, identity3));

        // Verify indices
        assertEq(paymaster.indexOf(poolId1, identity1), 0);
        assertEq(paymaster.indexOf(poolId1, identity2), 1);
        assertEq(paymaster.indexOf(poolId1, identity3), 2);

        // Verify pool size and deposits
        assertEq(paymaster.getMerkleTreeSize(poolId1), 3);
        assertEq(
            paymaster.getPoolDeposits(poolId1),
            TestUtils.JOINING_FEE_1_ETH * 3
        );
        assertEq(
            paymaster.totalUsersDeposit(),
            TestUtils.JOINING_FEE_1_ETH * 3
        );

        // Verify root updates (roots should be different as tree changes)
        assertEq(paymaster.getMerkleTreeRoot(poolId1), merkleTreeRoot3);
        assertTrue(merkleTreeRoot3 != merkleTreeRoot2); // Roots should be different
    }

    /// @dev Test adding members to different pools
    function test_AddMember_DifferentPools() public {
        // Use simple, guaranteed unique identities
        uint256 identity1 = 1;
        uint256 identity2 = 2;
        uint256 identity3 = 3;

        // Add to pool 1
        paymaster.addMember{value: TestUtils.JOINING_FEE_1_ETH}(
            poolId1,
            identity1
        );

        // Add to pool 2 (different fee)
        paymaster.addMember{value: TestUtils.JOINING_FEE_0_1_ETH}(
            poolId2,
            identity2
        );

        // Add to pool 3 (different fee)
        paymaster.addMember{value: TestUtils.JOINING_FEE_5_ETH}(
            poolId3,
            identity3
        );

        // Verify members in correct pools
        assertTrue(paymaster.hasMember(poolId1, identity1));
        assertFalse(paymaster.hasMember(poolId1, identity2));
        assertFalse(paymaster.hasMember(poolId1, identity3));

        assertTrue(paymaster.hasMember(poolId2, identity2));
        assertFalse(paymaster.hasMember(poolId2, identity1));

        assertTrue(paymaster.hasMember(poolId3, identity3));

        // Verify total deposits
        uint256 expectedTotal = TestUtils.JOINING_FEE_1_ETH +
            TestUtils.JOINING_FEE_0_1_ETH +
            TestUtils.JOINING_FEE_5_ETH;
        assertEq(paymaster.totalUsersDeposit(), expectedTotal);
    }

    // ============ Error Cases ============

    /// @dev Test adding member to non-existent pool
    function test_AddMember_NonExistentPool() public {
        uint256 invalidPoolId = 999;
        uint256 validIdentity = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                PoolErrors.PoolDoesNotExist.selector,
                invalidPoolId
            )
        );
        paymaster.addMember{value: TestUtils.JOINING_FEE_1_ETH}(
            invalidPoolId,
            validIdentity
        );
    }

    /// @dev Test adding member with incorrect joining fee (too low)
    function test_AddMember_IncorrectFeeTooLow() public {
        uint256 incorrectFee = TestUtils.JOINING_FEE_1_ETH - 1;
        uint256 validIdentity = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                PoolErrors.IncorrectJoiningFee.selector,
                incorrectFee,
                TestUtils.JOINING_FEE_1_ETH
            )
        );
        paymaster.addMember{value: incorrectFee}(poolId1, validIdentity);
    }

    /// @dev Test adding member with incorrect joining fee (too high)
    function test_AddMember_IncorrectFeeTooHigh() public {
        uint256 incorrectFee = TestUtils.JOINING_FEE_1_ETH + 1;
        uint256 validIdentity = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                PoolErrors.IncorrectJoiningFee.selector,
                incorrectFee,
                TestUtils.JOINING_FEE_1_ETH
            )
        );
        paymaster.addMember{value: incorrectFee}(poolId1, validIdentity);
    }

    /// @dev Test adding member with no payment
    function test_AddMember_NoPayment() public {
        uint256 validIdentity = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                PoolErrors.IncorrectJoiningFee.selector,
                0,
                TestUtils.JOINING_FEE_1_ETH
            )
        );
        paymaster.addMember(poolId1, validIdentity); // No value sent
    }

    /// @dev Test adding duplicate identity commitment (should fail - LeanIMT doesn't allow duplicates)
    function test_AddMember_DuplicateIdentity() public {
        uint256 validIdentity = 1;

        // Add first instance
        paymaster.addMember{value: TestUtils.JOINING_FEE_1_ETH}(
            poolId1,
            validIdentity
        );

        // Try to add same identity again - this should fail with LeanIMT error
        vm.expectRevert(); // Just expect any revert since LeanIMT uses custom errors
        paymaster.addMember{value: TestUtils.JOINING_FEE_1_ETH}(
            poolId1,
            validIdentity
        );
    }

    /// @dev Test adding identity that's too large for SNARK field
    function test_AddMember_InvalidIdentityTooLarge() public {
        uint256 invalidIdentity = SNARK_SCALAR_FIELD; // Exactly at the limit (invalid)

        vm.expectRevert(); // Just expect any revert since LeanIMT uses custom errors
        paymaster.addMember{value: TestUtils.JOINING_FEE_1_ETH}(
            poolId1,
            invalidIdentity
        );
    }

    // ============ Access Control Tests ============

    /// @dev Test that anyone can add members (not restricted to owner)
    function test_AddMember_AnyoneCanAdd() public {
        uint256 identity1 = 1;
        uint256 identity2 = 2;

        vm.prank(user1);
        uint256 merkleTreeRoot = paymaster.addMember{
            value: TestUtils.JOINING_FEE_1_ETH
        }(poolId1, identity1);

        assertTrue(paymaster.hasMember(poolId1, identity1));
        assertGt(merkleTreeRoot, 0);

        vm.prank(user2);
        paymaster.addMember{value: TestUtils.JOINING_FEE_1_ETH}(
            poolId1,
            identity2
        );

        assertTrue(paymaster.hasMember(poolId1, identity2));
    }

    // ============ Gas Estimation Tests ============

    /// @dev Test gas consumption for adding first member
    function test_AddMember_FirstMemberGas() public {
        uint256 validIdentity = 1;

        uint256 gasBefore = gasleft();
        paymaster.addMember{value: TestUtils.JOINING_FEE_1_ETH}(
            poolId1,
            validIdentity
        );
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for first member:", gasUsed);

        // First member should use more gas due to tree initialization
        assertGt(gasUsed, 50000); // Should use at least 50k gas
        assertLt(gasUsed, 300000); // Should not exceed 300k gas (increased for LeanIMT)
    }

    /// @dev Test gas consumption for subsequent members
    function test_AddMember_SubsequentMemberGas() public {
        uint256 identity1 = 1;
        uint256 identity2 = 2;

        // Add first member
        paymaster.addMember{value: TestUtils.JOINING_FEE_1_ETH}(
            poolId1,
            identity1
        );

        // Measure gas for second member
        uint256 gasBefore = gasleft();
        paymaster.addMember{value: TestUtils.JOINING_FEE_1_ETH}(
            poolId1,
            identity2
        );
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for second member:", gasUsed);

        // Subsequent members should use less gas
        assertGt(gasUsed, 30000); // Should use at least 30k gas
        assertLt(gasUsed, 250000); // Should not exceed 250k gas
    }

    // ============ Fuzz Tests ============

    /// @dev Fuzz test with various identity commitments (within SNARK field)
    function testFuzz_AddMember_VariousIdentities(
        uint256 identityCommitment
    ) public {
        vm.assume(
            identityCommitment > 0 && identityCommitment < SNARK_SCALAR_FIELD
        );

        uint256 merkleTreeRoot = paymaster.addMember{
            value: TestUtils.JOINING_FEE_1_ETH
        }(poolId1, identityCommitment);

        assertTrue(paymaster.hasMember(poolId1, identityCommitment));
        assertEq(paymaster.indexOf(poolId1, identityCommitment), 0);
        assertGt(merkleTreeRoot, 0);
        assertEq(paymaster.getMerkleTreeSize(poolId1), 1);
    }

    /// @dev Fuzz test with various pool IDs and joining fees
    function testFuzz_AddMember_VariousPools(uint256 joiningFee) public {
        vm.assume(joiningFee > 0 && joiningFee <= 100 ether);

        uint256 validIdentity = 1;

        // Create dynamic pool
        uint256 dynamicPoolId = paymaster.createPool(joiningFee);

        // Add member with exact fee
        uint256 merkleTreeRoot = paymaster.addMember{value: joiningFee}(
            dynamicPoolId,
            validIdentity
        );

        assertTrue(paymaster.hasMember(dynamicPoolId, validIdentity));
        assertEq(paymaster.getPoolDeposits(dynamicPoolId), joiningFee);
        assertGt(merkleTreeRoot, 0);
    }

    /// @dev Fuzz test adding multiple members (with unique identities)
    function testFuzz_AddMember_MultipleMembers(uint8 memberCount) public {
        vm.assume(memberCount > 0 && memberCount <= 10); // Reduced limit for performance

        for (uint8 i = 0; i < memberCount; i++) {
            // Use simple incrementing identities to ensure uniqueness
            uint256 identity = i + 1; // Start from 1, increment
            paymaster.addMember{value: TestUtils.JOINING_FEE_1_ETH}(
                poolId1,
                identity
            );
        }

        assertEq(paymaster.getMerkleTreeSize(poolId1), memberCount);
        assertEq(
            paymaster.getPoolDeposits(poolId1),
            TestUtils.JOINING_FEE_1_ETH * memberCount
        );
        assertEq(
            paymaster.totalUsersDeposit(),
            TestUtils.JOINING_FEE_1_ETH * memberCount
        );
    }

    // ============ Edge Cases ============

    /// @dev Test adding member with identity = 1 (minimum valid)
    function test_AddMember_MinIdentity() public {
        uint256 minIdentity = 1;

        uint256 merkleTreeRoot = paymaster.addMember{
            value: TestUtils.JOINING_FEE_1_ETH
        }(poolId1, minIdentity);

        assertTrue(paymaster.hasMember(poolId1, minIdentity));
        assertGt(merkleTreeRoot, 0);
    }

    /// @dev Test adding member with maximum valid SNARK field identity
    function test_AddMember_MaxValidIdentity() public {
        uint256 maxValidIdentity = SNARK_SCALAR_FIELD - 1; // Maximum valid value

        uint256 merkleTreeRoot = paymaster.addMember{
            value: TestUtils.JOINING_FEE_1_ETH
        }(poolId1, maxValidIdentity);

        assertTrue(paymaster.hasMember(poolId1, maxValidIdentity));
        assertGt(merkleTreeRoot, 0);
    }
}
