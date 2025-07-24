// file:prepaid-gas-paymaster-contracts/contracts/new/interfaces/IPrepaidGasPool.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// import {ProofLib} from './lib/ProofLib.sol';
import {IState} from "./IState.sol";

/**
 * @title IPrivacyPool
 * @notice Interface for the PrivacyPool contract
 */
interface IPrepaidGasPool is IState {
    /*///////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted irreversibly suspending deposits
     */
    event PoolDied();

    /**
     * @notice Emitted when making a user deposit
     * @param _depositor The address of the depositor
     * @param _commitment The commitment hash
     */
    event Deposited(address indexed _depositor, uint256 _commitment);

    /*///////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Thrown when failing to verify a withdrawal proof through the Groth16 verifier
     */
    error InvalidProof();

    /**
     * @notice Thrown when trying to spend a commitment that does not exist in the state
     */
    error InvalidCommitment();

    /**
     * @notice Thrown when calling `withdraw` with a ASP or state tree depth greater or equal than the max tree depth
     */
    error InvalidTreeDepth();

    /**
     * @notice Thrown when providing an invalid scope for this pool
     */
    error ScopeMismatch();

    /**
     * @notice Thrown when providing an invalid context for the pool and withdrawal
     */
    error ContextMismatch();

    /**
     * @notice Thrown when providing an unknown or outdated state root
     */
    error UnknownStateRoot();

    /**
     * @notice Thrown when sending less amount of native asset than required
     */
    error InsufficientValue();

    /*///////////////////////////////////////////////////////////////
                              LOGIC
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Deposit funds into the Privacy Pool
     * @dev Only callable by the Entrypoint
     * @param _commitment The commitment hash
     */
    function deposit(uint256 _commitment) external payable;
}
