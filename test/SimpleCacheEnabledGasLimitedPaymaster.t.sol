// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/SimpleCacheGasLimitedPaymaster.sol";
import "../contracts/interfaces/IPoolManager.sol";
import "../contracts/interfaces/IPoolMembershipProofVerifier.sol";
import "../contracts/errors/BaseErrors.sol";
import "../contracts/errors/PoolErrors.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title Mock EntryPoint for testing
contract MockEntryPoint is IERC165 {
    mapping(address => uint256) public balanceOf;

    function supportsInterface(
        bytes4 interfaceId
    ) public pure override returns (bool) {
        return
            interfaceId == type(IEntryPoint).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    function depositTo(address account) external payable {
        balanceOf[account] += msg.value;
    }

    function withdrawTo(
        address payable withdrawAddress,
        uint256 amount
    ) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        withdrawAddress.transfer(amount);
    }

    function addStake(uint32) external payable {
        // Mock implementation
    }

    function unlockStake() external {
        // Mock implementation
    }

    function withdrawStake(address payable) external {
        // Mock implementation
    }

    receive() external payable {}
}

/// @title Mock ZK Verifier for testing
contract MockPoolMembershipProofVerifier is IPoolMembershipProofVerifier {
    bool public shouldReturnValid = true;

    function setShouldReturnValid(bool _shouldReturnValid) external {
        shouldReturnValid = _shouldReturnValid;
    }

    function verifyProof(
        uint[2] memory, // _pA
        uint[2][2] memory, // _pB
        uint[2] memory, // _pC
        uint[4] memory, // _pubSignals
        uint256 // merkleTreeDepth
    ) external view override returns (bool) {
        return shouldReturnValid;
    }
}

/// @title Basic deployment and initialization tests
contract SimpleCacheEnabledGasLimitedPaymasterTest is Test {
    SimpleCacheEnabledGasLimitedPaymaster public paymaster;
    MockPoolMembershipProofVerifier public mockVerifier;
    MockEntryPoint public mockEntryPoint;

    address public owner;
    address public user1;
    address public user2;

    uint256 constant DEFAULT_JOINING_FEE = 1 ether;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock contracts
        mockVerifier = new MockPoolMembershipProofVerifier();
        mockEntryPoint = new MockEntryPoint();

        // Deploy paymaster with mocks
        paymaster = new SimpleCacheEnabledGasLimitedPaymaster(
            address(mockEntryPoint),
            address(mockVerifier)
        );

        // Fund the test contract for operations
        vm.deal(address(this), 100 ether);
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    /// @dev Test successful deployment
    function test_DeploymentSuccess() public {
        assertEq(address(paymaster.entryPoint()), address(mockEntryPoint));
        assertEq(address(paymaster.verifier()), address(mockVerifier));
        assertEq(paymaster.owner(), owner);
        assertEq(paymaster.totalUsersDeposit(), 0);
        assertEq(paymaster.poolCounter(), 0);
    }

    /// @dev Test deployment with invalid verifier address
    function test_DeploymentWithInvalidVerifier() public {
        vm.expectRevert(BaseErrors.InvalidVerifierAddress.selector);
        new SimpleCacheEnabledGasLimitedPaymaster(
            address(mockEntryPoint),
            address(0)
        );
    }

    /// @dev Test deployment with invalid EntryPoint address
    function test_DeploymentWithInvalidEntryPoint() public {
        vm.expectRevert(BaseErrors.InvalidEntryPoint.selector);
        new SimpleCacheEnabledGasLimitedPaymaster(
            address(0),
            address(mockVerifier)
        );
    }

    /// @dev Fuzz test deployment with various verifier addresses
    function testFuzz_DeploymentWithVariousVerifiers(
        address verifierAddr
    ) public {
        vm.assume(verifierAddr != address(0));

        // Create a mock verifier at the given address that supports the interface
        vm.mockCall(
            verifierAddr,
            abi.encodeWithSelector(
                IPoolMembershipProofVerifier.verifyProof.selector
            ),
            abi.encode(true)
        );

        SimpleCacheEnabledGasLimitedPaymaster testPaymaster = new SimpleCacheEnabledGasLimitedPaymaster(
                address(mockEntryPoint),
                verifierAddr
            );

        assertEq(address(testPaymaster.verifier()), verifierAddr);
        assertEq(address(testPaymaster.entryPoint()), address(mockEntryPoint));
    }
}

/// @title Pool management tests
contract PoolManagementTest is Test {
    SimpleCacheEnabledGasLimitedPaymaster public paymaster;
    MockPoolMembershipProofVerifier public mockVerifier;
    MockEntryPoint public mockEntryPoint;

    address public owner;
    address public user1;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");

        mockVerifier = new MockPoolMembershipProofVerifier();
        mockEntryPoint = new MockEntryPoint();

        paymaster = new SimpleCacheEnabledGasLimitedPaymaster(
            address(mockEntryPoint),
            address(mockVerifier)
        );

        vm.deal(address(this), 100 ether);
        vm.deal(user1, 10 ether);
    }

    /// @dev Test successful pool creation
    function test_CreatePool() public {
        uint256 joiningFee = 1 ether;

        vm.expectEmit(true, false, false, true);
        emit IPoolManager.PoolCreated(1, joiningFee);

        uint256 poolId = paymaster.createPool(joiningFee);

        assertEq(poolId, 1);
        assertEq(paymaster.poolCounter(), 1);
        assertTrue(paymaster.poolExists(poolId));
        assertEq(paymaster.getJoiningFee(poolId), joiningFee);
        assertEq(paymaster.getPoolDeposits(poolId), 0);
    }

    /// @dev Test pool creation with zero joining fee (should fail)
    function test_CreatePoolWithZeroFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(PoolErrors.InvalidJoiningFee.selector, 0)
        );
        paymaster.createPool(0);
    }

    /// @dev Test only owner can create pools
    function test_CreatePoolOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                user1
            )
        );
        paymaster.createPool(1 ether);
    }

    /// @dev Fuzz test pool creation with various joining fees
    function testFuzz_CreatePoolWithVariousFees(uint256 joiningFee) public {
        vm.assume(joiningFee > 0 && joiningFee <= 1000 ether);

        uint256 poolId = paymaster.createPool(joiningFee);

        assertEq(paymaster.getJoiningFee(poolId), joiningFee);
        assertTrue(paymaster.poolExists(poolId));
    }
}
