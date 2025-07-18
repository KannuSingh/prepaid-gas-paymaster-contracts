// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// Simple interface for testing without full contract compilation
interface ISimplePaymaster {
    function owner() external view returns (address);

    function poolCounter() external view returns (uint256);

    function totalUsersDeposit() external view returns (uint256);

    function createPool(uint256 joiningFee) external returns (uint256);

    function getJoiningFee(uint256 poolId) external view returns (uint256);

    function poolExists(uint256 poolId) external view returns (bool);
}

/// @title Basic Mock Test
/// @notice Test that verifies mock contracts work independently
contract BasicMockTest is Test {
    // Add receive function to accept ETH transfers
    receive() external payable {}

    function test_MockContracts() public {
        // Test that our mock contracts can be deployed and work
        MockEntryPoint mockEntryPoint = new MockEntryPoint();
        SimpleMockPoolMembershipProofVerifier mockVerifier = new SimpleMockPoolMembershipProofVerifier(
                true
            );

        // Test MockEntryPoint
        assertEq(mockEntryPoint.balanceOf(address(this)), 0);
        mockEntryPoint.depositTo{value: 1 ether}(address(this));
        assertEq(mockEntryPoint.balanceOf(address(this)), 1 ether);

        // Test MockVerifier
        assertTrue(mockVerifier.alwaysReturn());
        mockVerifier.setResult(false);
        assertFalse(mockVerifier.alwaysReturn());

        // Test verifyProof call
        uint[2] memory pA;
        uint[2][2] memory pB;
        uint[2] memory pC;
        uint[4] memory pubSignals;

        assertFalse(mockVerifier.verifyProof(pA, pB, pC, pubSignals, 1));

        mockVerifier.setResult(true);
        assertTrue(mockVerifier.verifyProof(pA, pB, pC, pubSignals, 1));

        console.log(" Mock contracts work correctly");
    }

    /// @dev Test EntryPoint interface compliance
    function test_MockEntryPointInterface() public {
        MockEntryPoint mockEntryPoint = new MockEntryPoint();

        // Test interface support
        assertTrue(
            mockEntryPoint.supportsInterface(type(IEntryPoint).interfaceId)
        );
        assertTrue(mockEntryPoint.supportsInterface(type(IERC165).interfaceId));

        // Test deposit/withdraw functionality
        address testAccount = makeAddr("testAccount");
        vm.deal(address(this), 10 ether);
        vm.deal(testAccount, 1 ether); // Give testAccount some ETH so it can receive transfers

        mockEntryPoint.depositTo{value: 5 ether}(testAccount);
        assertEq(mockEntryPoint.balanceOf(testAccount), 5 ether);

        // Test withdraw (from testAccount perspective) - withdraw to this contract which has receive()
        uint256 balanceBefore = address(this).balance;
        vm.prank(testAccount);
        mockEntryPoint.withdrawTo(payable(address(this)), 2 ether);

        assertEq(mockEntryPoint.balanceOf(testAccount), 3 ether);
        assertEq(address(this).balance, balanceBefore + 2 ether);

        console.log(" MockEntryPoint interface works correctly");
    }

    /// @dev Test withdrawal to EOA (which can always receive ETH)
    function test_MockEntryPointWithdrawToEOA() public {
        MockEntryPoint mockEntryPoint = new MockEntryPoint();

        // Create an EOA that can receive ETH
        address payable recipient = payable(makeAddr("recipient"));
        vm.deal(address(this), 10 ether);

        // Deposit from this contract for this contract
        mockEntryPoint.depositTo{value: 3 ether}(address(this));
        assertEq(mockEntryPoint.balanceOf(address(this)), 3 ether);

        // Withdraw to EOA
        uint256 recipientBalanceBefore = recipient.balance;
        mockEntryPoint.withdrawTo(recipient, 1 ether);

        assertEq(mockEntryPoint.balanceOf(address(this)), 2 ether);
        assertEq(recipient.balance, recipientBalanceBefore + 1 ether);

        console.log(" MockEntryPoint withdrawal to EOA works correctly");
    }
}

// Import our mock contracts here to test them independently
import "../contracts/interfaces/IPoolMembershipProofVerifier.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title Mock EntryPoint for testing
contract MockEntryPoint is IERC165 {
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public stakes;
    mapping(address => uint256) public unstakeDelays;

    event Deposited(address indexed account, uint256 totalDeposit);
    event Withdrawn(
        address indexed account,
        address withdrawAddress,
        uint256 amount
    );

    function supportsInterface(
        bytes4 interfaceId
    ) public pure override returns (bool) {
        return
            interfaceId == type(IEntryPoint).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    function depositTo(address account) external payable {
        require(account != address(0), "Invalid account");
        balanceOf[account] += msg.value;
        emit Deposited(account, balanceOf[account]);
    }

    function withdrawTo(
        address payable withdrawAddress,
        uint256 amount
    ) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        require(withdrawAddress != address(0), "Invalid withdraw address");

        balanceOf[msg.sender] -= amount;
        withdrawAddress.transfer(amount);
        emit Withdrawn(msg.sender, withdrawAddress, amount);
    }

    function addStake(uint32 unstakeDelaySec) external payable {
        stakes[msg.sender] += msg.value;
        unstakeDelays[msg.sender] = unstakeDelaySec;
    }

    function unlockStake() external {
        require(stakes[msg.sender] > 0, "No stake to unlock");
    }

    function withdrawStake(address payable withdrawAddress) external {
        require(stakes[msg.sender] > 0, "No stake to withdraw");
        require(withdrawAddress != address(0), "Invalid withdraw address");

        uint256 amount = stakes[msg.sender];
        stakes[msg.sender] = 0;
        withdrawAddress.transfer(amount);
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

/// @title Simple Mock ZK Proof Verifier
contract SimpleMockPoolMembershipProofVerifier is IPoolMembershipProofVerifier {
    bool public alwaysReturn;

    constructor(bool _alwaysReturn) {
        alwaysReturn = _alwaysReturn;
    }

    function setResult(bool _result) external {
        alwaysReturn = _result;
    }

    function verifyProof(
        uint[2] memory,
        uint[2][2] memory,
        uint[2] memory,
        uint[4] memory,
        uint256
    ) external view override returns (bool) {
        return alwaysReturn;
    }
}
