// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../contracts/interfaces/IPoolMembershipProofVerifier.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title Mock EntryPoint for testing
/// @notice Simplified EntryPoint mock that tracks deposits and supports required interfaces
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
    event StakeAdded(
        address indexed account,
        uint256 totalStaked,
        uint256 unstakeDelaySec
    );
    event StakeUnlocked(address indexed account, uint256 withdrawTime);
    event StakeWithdrawn(
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

    /// @notice Deposit funds for a paymaster
    function depositTo(address account) external payable {
        require(account != address(0), "Invalid account");
        balanceOf[account] += msg.value;
        emit Deposited(account, balanceOf[account]);
    }

    /// @notice Withdraw funds from paymaster deposit
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

    /// @notice Add stake for paymaster
    function addStake(uint32 unstakeDelaySec) external payable {
        stakes[msg.sender] += msg.value;
        unstakeDelays[msg.sender] = unstakeDelaySec;
        emit StakeAdded(msg.sender, stakes[msg.sender], unstakeDelaySec);
    }

    /// @notice Unlock stake for withdrawal
    function unlockStake() external {
        require(stakes[msg.sender] > 0, "No stake to unlock");
        // In a real implementation, this would set a withdrawal time
        emit StakeUnlocked(
            msg.sender,
            block.timestamp + unstakeDelays[msg.sender]
        );
    }

    /// @notice Withdraw stake
    function withdrawStake(address payable withdrawAddress) external {
        require(stakes[msg.sender] > 0, "No stake to withdraw");
        require(withdrawAddress != address(0), "Invalid withdraw address");

        uint256 amount = stakes[msg.sender];
        stakes[msg.sender] = 0;
        withdrawAddress.transfer(amount);
        emit StakeWithdrawn(msg.sender, withdrawAddress, amount);
    }

    /// @notice Get stake info (for compatibility)
    function getStakeInfo(
        address account
    ) external view returns (uint256 stake, uint256 unstakeDelaySec) {
        return (stakes[account], unstakeDelays[account]);
    }

    receive() external payable {
        // Allow direct deposits to the EntryPoint
        balanceOf[msg.sender] += msg.value;
    }
}

/// @title Mock ZK Proof Verifier for testing
/// @notice Configurable mock that can simulate proof verification success/failure
contract MockPoolMembershipProofVerifier is IPoolMembershipProofVerifier {
    bool public shouldReturnValid = true;
    bool public shouldRevert = false;
    string public revertMessage = "Mock verification failed";

    // Track verification calls for testing (manual tracking since verifyProof must be view)
    uint256 public verificationCallCount;
    mapping(uint256 => bool) public verificationResults;

    event ProofVerificationCalled(
        uint256 indexed callNumber,
        uint256 merkleTreeDepth,
        bool result
    );

    /// @notice Configure mock behavior
    function setShouldReturnValid(bool _shouldReturnValid) external {
        shouldReturnValid = _shouldReturnValid;
    }

    /// @notice Configure mock to revert on verification
    function setShouldRevert(
        bool _shouldRevert,
        string memory _revertMessage
    ) external {
        shouldRevert = _shouldRevert;
        revertMessage = _revertMessage;
    }

    /// @notice Reset verification call tracking
    function resetCallCount() external {
        verificationCallCount = 0;
    }

    /// @notice Set specific result for a specific call number
    function setResultForCall(uint256 callNumber, bool result) external {
        verificationResults[callNumber] = result;
    }

    /// @notice Increment call count (helper for testing - call this manually in tests)
    function incrementCallCount() external {
        verificationCallCount++;
    }

    /// @notice Mock proof verification - must be view to match interface
    function verifyProof(
        uint[2] memory, // _pA
        uint[2][2] memory, // _pB
        uint[2] memory, // _pC
        uint[4] memory, // _pubSignals
        uint256 /* merkleTreeDepth */
    ) external view override returns (bool) {
        if (shouldRevert) {
            revert(revertMessage);
        }

        // Check for specific result first (based on current call count + 1)
        uint256 nextCall = verificationCallCount + 1;
        if (verificationResults[nextCall]) {
            return verificationResults[nextCall];
        }

        // Default behavior
        return shouldReturnValid;
    }

    /// @notice Get verification statistics
    function getVerificationStats()
        external
        view
        returns (uint256 totalCalls, bool defaultResult)
    {
        return (verificationCallCount, shouldReturnValid);
    }
}

/// @title Simple Mock ZK Proof Verifier
/// @notice Simpler version for basic testing scenarios
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

/// @title Test Utilities
/// @notice Helper functions and constants for testing
library TestUtils {
    // SNARK scalar field modulus (roughly 2^254)
    uint256 public constant SNARK_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // Common test identity commitments (all within SNARK field)
    uint256 public constant IDENTITY_1 =
        0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef %
            SNARK_SCALAR_FIELD;
    uint256 public constant IDENTITY_2 =
        0xfedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321 %
            SNARK_SCALAR_FIELD;
    uint256 public constant IDENTITY_3 =
        0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890 %
            SNARK_SCALAR_FIELD;
    uint256 public constant IDENTITY_4 =
        0x1111111111111111111111111111111111111111111111111111111111111111 %
            SNARK_SCALAR_FIELD;
    uint256 public constant IDENTITY_5 =
        0x2222222222222222222222222222222222222222222222222222222222222222 %
            SNARK_SCALAR_FIELD;

    // Common joining fees
    uint256 public constant JOINING_FEE_0_01_ETH = 0.01 ether;
    uint256 public constant JOINING_FEE_0_1_ETH = 0.1 ether;
    uint256 public constant JOINING_FEE_1_ETH = 1 ether;
    uint256 public constant JOINING_FEE_5_ETH = 5 ether;
    uint256 public constant JOINING_FEE_10_ETH = 10 ether;

    /// @notice Generate a deterministic identity commitment for testing (within SNARK field)
    function generateIdentity(
        string memory seed
    ) internal pure returns (uint256) {
        return
            uint256(keccak256(abi.encodePacked("identity_", seed))) %
            SNARK_SCALAR_FIELD;
    }

    /// @notice Generate multiple unique identity commitments (within SNARK field)
    function generateIdentities(
        uint256 count
    ) internal pure returns (uint256[] memory) {
        uint256[] memory identities = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            identities[i] = generateIdentity(
                string(abi.encodePacked("test_", i))
            );
        }
        return identities;
    }

    /// @notice Generate a unique identity for a specific test run to avoid collisions
    function generateUniqueIdentity(
        string memory seed,
        uint256 nonce
    ) internal view returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encodePacked("unique_", seed, nonce, block.timestamp)
                )
            ) % SNARK_SCALAR_FIELD;
    }

    /// @notice Validate identity is within SNARK field
    function isValidIdentity(uint256 identity) internal pure returns (bool) {
        return identity > 0 && identity < SNARK_SCALAR_FIELD;
    }

    /// @notice Calculate expected merkle tree depth for given size
    function calculateExpectedDepth(
        uint256 size
    ) internal pure returns (uint256) {
        if (size == 0) return 0;

        uint256 depth = 0;
        uint256 temp = size - 1;
        while (temp > 0) {
            depth++;
            temp >>= 1;
        }
        return depth;
    }
}
