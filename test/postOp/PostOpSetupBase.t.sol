// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../contracts/SimpleCacheGasLimitedPaymaster.sol";
import "../../contracts/interfaces/IPoolManager.sol";
import "../../contracts/base/PostOpContextLib.sol";
import "../../contracts/base/NullifierCacheStateLib.sol";
import "../../contracts/base/Constants.sol";
import "../../contracts/errors/PaymasterValidationErrors.sol";
import "../../contracts/errors/PoolErrors.sol";
import "../mocks/MockContracts.sol";

/// @title PostOpSetupBase
/// @notice Base setup for PostOp testing - shared infrastructure
abstract contract PostOpSetupBase is Test {
    using NullifierCacheStateLib for uint256;

    // ============ Contract Instances ============
    SimpleCacheEnabledGasLimitedPaymaster public paymaster;
    MockPoolMembershipProofVerifier public mockVerifier;
    MockEntryPoint public mockEntryPoint;

    // ============ Test Addresses ============
    address public owner;
    address public user1;
    address public user2;
    address public user3;
    address public sender1; // Smart account addresses
    address public sender2;
    address public sender3;

    // ============ Pool Configuration ============
    uint256 public poolId1;
    uint256 public poolId2;
    uint256 public poolId3;

    uint256 public constant JOINING_FEE_1_ETH = TestUtils.JOINING_FEE_1_ETH;
    uint256 public constant JOINING_FEE_0_1_ETH = TestUtils.JOINING_FEE_0_1_ETH;
    uint256 public constant JOINING_FEE_5_ETH = TestUtils.JOINING_FEE_5_ETH;

    // ============ Test Data ============
    uint256[] public identities;
    bytes32[] public userOpHashes;
    uint256[] public nullifiers;

    // ============ State Tracking ============
    mapping(address => bytes32) public userStateKeys;
    mapping(address => uint256) public userNullifierStates;

    // ============ Events for Testing ============
    event UserOpSponsoredActivation(
        bytes32 indexed userOpHash,
        uint256 indexed poolId,
        address sender,
        uint256 actualGasCost,
        uint256 nullifier
    );

    event UserOpSponsoredCached(
        bytes32 indexed userOpHash,
        uint256 indexed poolId,
        address sender,
        uint256 actualGasCost,
        uint256 nullifierIndices
    );

    function setUp() public virtual {
        _initializeAddresses();
        _deployContracts();
        _fundAccounts();
        _createPools();
        _generateTestData();
        _addMembersToTestPools();
        _initializeUserStateKeys();
        _verifySetupState();

        console.log("PostOp setup completed successfully");
    }

    // ============ Setup Helper Functions ============

    function _initializeAddresses() internal {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        sender1 = makeAddr("smartAccount1");
        sender2 = makeAddr("smartAccount2");
        sender3 = makeAddr("smartAccount3");
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
        vm.deal(user3, 50 ether);

        mockEntryPoint.depositTo{value: 100 ether}(address(paymaster));
    }

    function _createPools() internal {
        poolId1 = paymaster.createPool(JOINING_FEE_1_ETH);
        poolId2 = paymaster.createPool(JOINING_FEE_0_1_ETH);
        poolId3 = paymaster.createPool(JOINING_FEE_5_ETH);
    }

    function _generateTestData() internal {
        // Generate identities
        for (uint256 i = 1; i <= 10; i++) {
            uint256 identity = TestUtils.generateIdentity(
                string(abi.encodePacked("postop_test_", i))
            );
            identities.push(identity);
        }

        // Generate UserOp hashes
        for (uint256 i = 1; i <= 5; i++) {
            bytes32 hash = keccak256(
                abi.encodePacked("userOp_", i, block.timestamp)
            );
            userOpHashes.push(hash);
        }

        // Generate nullifiers
        for (uint256 i = 1; i <= 10; i++) {
            uint256 nullifier = uint256(
                keccak256(abi.encodePacked("nullifier_", i, block.number))
            ) % TestUtils.SNARK_SCALAR_FIELD;
            nullifiers.push(nullifier);
        }
    }

    function _addMembersToTestPools() internal {
        for (uint256 i = 0; i < 3; i++) {
            paymaster.addMember{value: JOINING_FEE_1_ETH}(
                poolId1,
                identities[i]
            );
        }

        for (uint256 i = 3; i < 5; i++) {
            paymaster.addMember{value: JOINING_FEE_0_1_ETH}(
                poolId2,
                identities[i]
            );
        }

        paymaster.addMember{value: JOINING_FEE_5_ETH}(poolId3, identities[5]);
    }

    function _initializeUserStateKeys() internal {
        userStateKeys[sender1] = keccak256(abi.encode(poolId1, sender1));
        userStateKeys[sender2] = keccak256(abi.encode(poolId2, sender2));
        userStateKeys[sender3] = keccak256(abi.encode(poolId3, sender3));

        userNullifierStates[sender1] = 0;
        userNullifierStates[sender2] = 0;
        userNullifierStates[sender3] = 0;
    }

    function _verifySetupState() internal view {
        assertTrue(paymaster.poolExists(poolId1));
        assertTrue(paymaster.poolExists(poolId2));
        assertTrue(paymaster.poolExists(poolId3));

        assertEq(paymaster.getJoiningFee(poolId1), JOINING_FEE_1_ETH);
        assertEq(paymaster.getJoiningFee(poolId2), JOINING_FEE_0_1_ETH);
        assertEq(paymaster.getJoiningFee(poolId3), JOINING_FEE_5_ETH);

        assertEq(paymaster.getMerkleTreeSize(poolId1), 3);
        assertEq(paymaster.getMerkleTreeSize(poolId2), 2);
        assertEq(paymaster.getMerkleTreeSize(poolId3), 1);

        assertGt(mockEntryPoint.balanceOf(address(paymaster)), 50 ether);
    }

    // ============ Helper Functions ============

    function getIdentity(uint256 index) public view returns (uint256) {
        require(index < identities.length, "Identity index out of bounds");
        return identities[index];
    }

    function getUserOpHash(uint256 index) public view returns (bytes32) {
        require(index < userOpHashes.length, "UserOp hash index out of bounds");
        return userOpHashes[index];
    }

    function getNullifier(uint256 index) public view returns (uint256) {
        require(index < nullifiers.length, "Nullifier index out of bounds");
        return nullifiers[index];
    }

    function getUserStateKey(
        address sender,
        uint256 poolId
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(poolId, sender));
    }

    function getPaymasterBalance() public view returns (uint256) {
        return mockEntryPoint.balanceOf(address(paymaster));
    }

    function getPoolDeposits(uint256 poolId) public view returns (uint256) {
        return paymaster.getPoolDeposits(poolId);
    }

    // ============ Context Creation Helpers ============

    function createActivationContext(
        uint256 poolId,
        address sender,
        uint256 nullifier,
        uint256 userNullifiersState,
        uint256 userOpHashIndex
    ) public view returns (bytes memory context) {
        require(
            userOpHashIndex < userOpHashes.length,
            "UserOp hash index out of bounds"
        );

        bytes32 userOpHash = userOpHashes[userOpHashIndex];
        bytes32 userStateKey = keccak256(abi.encode(poolId, sender));

        context = PostOpContextLib.encodeActivationContext(
            poolId,
            userOpHash,
            nullifier,
            userNullifiersState,
            userStateKey,
            sender
        );

        require(context.length == 181, "Invalid activation context length");
    }

    function createCachedContext(
        uint256 poolId,
        address sender,
        uint256 joiningFee,
        uint256 userNullifiersState,
        uint256 userOpHashIndex
    ) public view returns (bytes memory context) {
        require(
            userOpHashIndex < userOpHashes.length,
            "UserOp hash index out of bounds"
        );

        bytes32 userOpHash = userOpHashes[userOpHashIndex];
        bytes32 userStateKey = keccak256(abi.encode(poolId, sender));

        context = PostOpContextLib.encodeCachedContext(
            poolId,
            userOpHash,
            joiningFee,
            userNullifiersState,
            userStateKey,
            sender
        );

        require(context.length == 181, "Invalid cached context length");
    }

    function createFirstActivationContext(
        uint256 poolId,
        address sender,
        uint256 nullifierIndex,
        uint256 userOpHashIndex
    ) public view returns (bytes memory context) {
        require(
            nullifierIndex < nullifiers.length,
            "Nullifier index out of bounds"
        );

        uint256 nullifier = nullifiers[nullifierIndex];
        uint256 emptyState = 0;

        return
            createActivationContext(
                poolId,
                sender,
                nullifier,
                emptyState,
                userOpHashIndex
            );
    }

    function createCachedConsumptionContext(
        uint256 poolId,
        address sender,
        uint8 activatedCount,
        uint8 activeIndex,
        uint256 userOpHashIndex
    ) public view returns (bytes memory context) {
        require(
            activatedCount > 0 && activatedCount <= 2,
            "Invalid activated count"
        );
        require(activeIndex < 2, "Invalid active index");

        uint256 joiningFee = paymaster.getJoiningFee(poolId);

        uint256 activeState = NullifierCacheStateLib.encodeFlags(
            activatedCount,
            0,
            false,
            activeIndex
        );

        return
            createCachedContext(
                poolId,
                sender,
                joiningFee,
                activeState,
                userOpHashIndex
            );
    }

    // ============ Analysis Helpers ============

    function isActivationContext(
        bytes memory context
    ) public pure returns (bool isActivation) {
        if (context.length != 181) return false;

        uint8 mode;
        assembly {
            mode := byte(0, mload(add(context, 32)))
        }
        return mode == uint8(Constants.NullifierMode.ACTIVATION);
    }

    function getPoolIdFromContext(
        bytes memory context
    ) public pure returns (uint256 poolId) {
        require(context.length == 181, "Invalid context length");

        assembly {
            poolId := mload(add(context, 33))
        }
    }

    function encodeNullifierState(
        uint8 activatedCount,
        uint8 exhaustedSlotIndex,
        bool hasExhaustedSlot,
        uint8 activeIndex
    ) public pure returns (uint256 encoded) {
        return
            NullifierCacheStateLib.encodeFlags(
                activatedCount,
                exhaustedSlotIndex,
                hasExhaustedSlot,
                activeIndex
            );
    }

    function decodeNullifierState(
        uint256 encodedState
    )
        public
        pure
        returns (
            uint8 activatedCount,
            uint8 exhaustedSlotIndex,
            bool hasExhaustedSlot,
            uint8 activeIndex
        )
    {
        activatedCount = encodedState.getActivatedNullifierCount();
        exhaustedSlotIndex = encodedState.getExhaustedSlotIndex();
        hasExhaustedSlot = encodedState.getHasAvailableExhaustedSlot();
        activeIndex = encodedState.getActiveNullifierIndex();
    }
}
