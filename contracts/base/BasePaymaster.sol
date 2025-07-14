// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@account-abstraction/contracts/interfaces/IPaymaster.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {BaseErrors} from "../errors/BaseErrors.sol";
import "./Constants.sol"; // Ensure this import exists if used

/// @title BasePaymaster
/// @notice Secure paymaster base without general withdrawal capabilities (stake withdrawal is allowed)
/// @dev Only allows controlled deposits through pool joining mechanism for UserOp payments
abstract contract BasePaymaster is IPaymaster, Ownable {
    IEntryPoint public immutable entryPoint;

    // ============ Constructor ============
    constructor(IEntryPoint _entryPoint) Ownable(msg.sender) {
        if (address(_entryPoint) == address(0)) {
            revert BaseErrors.InvalidEntryPoint();
        }

        _validateEntryPointInterface(_entryPoint);
        entryPoint = _entryPoint;
    }

    // ============ Internal EntryPoint Interface Validation ============
    /// @notice Validate EntryPoint interface compliance
    function _validateEntryPointInterface(
        IEntryPoint _entryPoint
    ) internal view virtual {
        // Changed to view as it doesn't modify state
        if (
            !IERC165(address(_entryPoint)).supportsInterface(
                type(IEntryPoint).interfaceId
            )
        ) {
            revert BaseErrors.InvalidEntryPoint(); // Use the specific error
        }
    }

    // ============ IPaymaster Implementation (Delegating to Internal Virtuals) ============
    /// @inheritdoc IPaymaster
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external override returns (bytes memory context, uint256 validationData) {
        _requireFromEntryPoint();
        return _validatePaymasterUserOp(userOp, userOpHash, maxCost);
    }

    /// @notice Internal validation logic to be implemented by derived contracts
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) internal virtual returns (bytes memory context, uint256 validationData);

    /// @inheritdoc IPaymaster
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override {
        _requireFromEntryPoint();
        _postOp(mode, context, actualGasCost, actualUserOpFeePerGas);
    }

    /// @notice Post-operation handler implementation
    /// @param mode Operation mode (succeeded, reverted, etc.)
    /// @param context Context data from validation phase
    /// @param actualGasCost Actual gas used
    /// @param actualUserOpFeePerGas Gas price for this operation
    function _postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) internal virtual;

    // ============ EntryPoint Deposit & Stake Management (Owner-Controlled) ============

    /// @notice Deposit funds to EntryPoint (internal only for this contract)
    /// @dev This function is internal. Derived contracts will handle how funds are received (e.g., via pool joining)
    /// and then call this to deposit them to the EntryPoint.
    function _depositToEntryPoint(uint256 amount) internal {
        // Ensure this contract holds the 'amount' before sending
        // (e.g., received from msg.value in a public function that calls this)
        entryPoint.depositTo{value: amount}(address(this));
    }

    /// @notice Get current deposit balance of this paymaster in the EntryPoint
    function getDeposit() public view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    /// @notice Add stake for this paymaster (only owner)
    /// @param unstakeDelaySec The unstake delay (can only be increased)
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    /// @notice Unlock the stake for withdrawal (only owner)
    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    /// @notice Withdraw the entire paymaster's stake (only owner)
    /// @param withdrawAddress The address to send withdrawn value
    function withdrawStake(address payable withdrawAddress) external onlyOwner {
        entryPoint.withdrawStake(withdrawAddress);
    }

    /// @notice Withdraw value from the deposit (owner-controlled, but default implementation prevents general withdrawal)
    /// @dev This function is intentionally implemented to revert to enforce "no general withdrawal" policy.
    /// Derived contracts that need specific withdrawal logic must override this.
    /// @param withdrawAddress Target to send to
    /// @param amount Amount to withdraw
    function withdrawTo(
        address payable withdrawAddress,
        uint256 amount
    ) external virtual onlyOwner {
        (withdrawAddress, amount);
        // Added onlyOwner as stake withdrawals are owner-only
        // This default implementation prevents direct withdrawals from the paymaster's deposit.
        // Funds are expected to be managed via the pool mechanisms.
        revert BaseErrors.WithdrawalNotAllowed();
    }

    // ============ Internal Utility Functions ============

    /// @notice Ensures that the caller is the EntryPoint contract.
    function _requireFromEntryPoint() internal view {
        if (msg.sender != address(entryPoint)) {
            revert BaseErrors.UnauthorizedCaller();
        }
    }
}
