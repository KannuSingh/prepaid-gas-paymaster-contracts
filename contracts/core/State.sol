// file:prepaid-gas-paymaster-contracts/contracts/new/core/State.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Constants} from "../lib/Constants.sol";
import {InternalLeanIMT, LeanIMTData} from "@zk-kit/lean-imt.sol/InternalLeanIMT.sol";

import {IState} from "../interfaces/IState.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";

/**
 * @title State
 * @notice Base contract for the managing the state of a PrepaidGas Pool
 * @custom:semver 0.1.0
 */
abstract contract State is IState {
    using InternalLeanIMT for LeanIMTData;

    /// @inheritdoc IState
    uint32 public constant ROOT_HISTORY_SIZE = 64;
    /// @inheritdoc IState
    uint32 public constant MIN_TREE_DEPTH = 1;
    /// @inheritdoc IState
    uint32 public constant MAX_TREE_DEPTH = 32;

    /// @inheritdoc IState
    uint256 public immutable SCOPE;
    /// @inheritdoc IState
    uint256 public immutable JOINING_AMOUNT;

    /// @inheritdoc IState
    IVerifier public immutable MEMBERSHIP_VERIFIER;

    // /// @inheritdoc IState
    // uint256 public nonce;
    /// @inheritdoc IState
    bool public dead;

    /// @inheritdoc IState
    mapping(uint256 _index => uint256 _root) public roots;
    /// @inheritdoc IState
    uint32 public currentRootIndex;

    // @notice The state merkle tree containing all commitments
    LeanIMTData internal _merkleTree;

    /// @inheritdoc IState
    uint256 public totalDeposit;

    /**
     * @notice Initialize the state addresses
     */
    constructor(uint256 _joiningAmount, address _membershipVerifier) {
        // Sanitize initial addresses
        if (_joiningAmount >= type(uint128).max) revert InvalidJoiningAmount();
        if (_membershipVerifier == address(0)) revert ZeroAddress();

        // Store asset address
        JOINING_AMOUNT = _joiningAmount;
        // Compute SCOPE
        SCOPE =
            uint256(
                keccak256(
                    abi.encodePacked(
                        address(this),
                        block.chainid,
                        _joiningAmount
                    )
                )
            ) %
            Constants.SNARK_SCALAR_FIELD;

        MEMBERSHIP_VERIFIER = IVerifier(_membershipVerifier);
    }

    /*///////////////////////////////////////////////////////////////
                              VIEWS
  //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IState
    function currentRoot() external view returns (uint256 _root) {
        _root = _merkleTree._root();
    }

    /// @inheritdoc IState
    function currentTreeDepth() external view returns (uint256 _depth) {
        _depth = _merkleTree.depth;
    }

    /// @inheritdoc IState
    function currentTreeSize() external view returns (uint256 _size) {
        _size = _merkleTree.size;
    }

    /*///////////////////////////////////////////////////////////////
                        INTERNAL METHODS
  //////////////////////////////////////////////////////////////*/

    // /**
    //  * @notice Spends a nullifier hash
    //  * @param _nullifierHash The nullifier hash to spend
    //  */
    // function _spend(uint256 _nullifierHash) internal {
    //     // Check if the nullifier is already spent
    //     if (nullifierHashes[_nullifierHash]) revert NullifierAlreadySpent();

    //     // Mark as spent
    //     nullifierHashes[_nullifierHash] = true;
    // }

    /**
     * @notice Insert a leaf into the state
     * @param _leaf The leaf to insert
     * @return _updatedRoot The new root after inserting the leaf
     */
    function _insert(uint256 _leaf) internal returns (uint256 _updatedRoot) {
        // Insert leaf in the tree
        _updatedRoot = _merkleTree._insert(_leaf);

        if (_merkleTree.depth > MAX_TREE_DEPTH) revert MaxTreeDepthReached();

        // Calculate the next index
        uint32 nextIndex = (currentRootIndex + 1) % ROOT_HISTORY_SIZE;

        // Store the root at the next index
        roots[nextIndex] = _updatedRoot;

        // Update currentRootIndex to point to the latest root
        currentRootIndex = nextIndex;

        emit LeafInserted(_merkleTree.size, _leaf, _updatedRoot);
    }

    /**
     * @notice Returns whether the root is a known root
     * @dev A circular buffer is used for root storage to decrease the cost of storing new roots
     * @dev Optimized to start search from most recent roots, improving average case performance
     * @param _root The root to check
     * @return Returns true if the root exists in the history, false otherwise
     */
    function _isKnownRoot(uint256 _root) internal view returns (bool) {
        if (_root == 0) return false;

        // Start from the most recent root (current index)
        uint32 _index = currentRootIndex;

        // Check all possible roots in the history
        for (uint32 _i = 0; _i < ROOT_HISTORY_SIZE; _i++) {
            if (_root == roots[_index]) return true;
            _index = (_index + ROOT_HISTORY_SIZE - 1) % ROOT_HISTORY_SIZE;
        }
        return false;
    }

    /**
     * @notice Returns whether a leaf is in the state
     * @param _leaf The leaf to check
     * @return Returns true if the leaf exists in the tree, false otherwise
     */
    function _isInState(uint256 _leaf) internal view returns (bool) {
        return _merkleTree._has(_leaf);
    }
}
