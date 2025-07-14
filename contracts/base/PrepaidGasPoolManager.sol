// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {PoolErrors} from "../errors/PoolErrors.sol";
import {InternalLeanIMT, LeanIMTData} from "@zk-kit/lean-imt.sol/InternalLeanIMT.sol";
import "./Constants.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrepaidGasPoolManager
/// @notice Abstract contract for managing privacy pools for prepaid gas system
abstract contract PrepaidGasPoolManager is IPoolManager, Ownable {
    using InternalLeanIMT for LeanIMTData;

    /// @notice Pool configuration
    // PrepaidGasPoolManager.sol
    struct PoolConfig {
        uint256 joiningFee;
        uint256 totalDeposits;
        uint256[64] rootsHistory;
        uint32 rootHistoryCurrentIndex;
        uint32 rootHistoryCount;
    }

    /// @notice Current pool counter (starts from 0, first pool will be 1)
    uint256 public poolCounter;

    /// @notice Mapping from pool ID to Lean IMT data
    mapping(uint256 => LeanIMTData) internal merkleTrees;

    /// @notice Pool configurations
    mapping(uint256 => PoolConfig) public pools;

    /// @notice Pool existence tracking
    mapping(uint256 => bool) public poolExists;

    // ============ Modifiers ============

    modifier onlyExistingPool(uint256 poolId) {
        if (!poolExists[poolId]) {
            revert PoolErrors.PoolDoesNotExist(poolId);
        }
        _;
    }

    modifier onlyNewPool(uint256 poolId) {
        if (poolExists[poolId]) {
            revert PoolErrors.PoolAlreadyExists(poolId);
        }
        _;
    }

    modifier onlyValidJoiningFee(uint256 joiningFee) {
        if (joiningFee == 0) {
            revert PoolErrors.InvalidJoiningFee(joiningFee);
        }
        _;
    }

    modifier onlyCorrectJoiningFee(uint256 poolId) {
        if (msg.value != pools[poolId].joiningFee) {
            revert PoolErrors.IncorrectJoiningFee(
                msg.value,
                pools[poolId].joiningFee
            );
        }
        _;
    }

    modifier onlyCorrectTotalJoiningFee(uint256 poolId, uint256 memberCount) {
        uint256 totalRequired = memberCount * pools[poolId].joiningFee;
        if (msg.value != totalRequired) {
            revert PoolErrors.IncorrectJoiningFee(msg.value, totalRequired);
        }
        _;
    }

    // ============ Abstract Functions (Must be implemented by concrete contracts) ============

    /// @inheritdoc IPoolManager
    /// @notice Creates a new prepaid gas pool with specified joining fee.
    /// Derived contracts must implement this, handling access control.
    /// It should internally call `_createPool`.
    function createPool(
        uint256 joiningFee
    ) external virtual override returns (uint256 poolId);

    /// @inheritdoc IPoolManager
    /// @notice Adds a single member to a pool (requires payment).
    /// Derived contracts must implement this, handling access control and `msg.value` checks.
    /// It should internally call `_addMember`.
    function addMember(
        uint256 poolId,
        uint256 identityCommitment
    ) external payable virtual override returns (uint256);

    /// @inheritdoc IPoolManager
    /// @notice Adds multiple members to a pool (requires payment).
    /// Derived contracts must implement this, handling access control and `msg.value` checks.
    /// It should internally call `_addMembers`.
    function addMembers(
        uint256 poolId,
        uint256[] calldata identityCommitments
    ) external payable virtual override returns (uint256);

    // ============ Internal Helper Functions ============

    /// @notice Internal function to create a new pool with common logic.
    /// This is called by the derived contract's `createPool` implementation.
    /// @param joiningFee The fee required to join this pool.
    /// @return newPoolId The ID of the newly created pool.
    function _createPool(
        uint256 joiningFee
    ) internal returns (uint256 newPoolId) {
        poolCounter++;
        newPoolId = poolCounter;

        // Ensure the generated newPoolId doesn't somehow already exist (safety check, very unlikely with a counter)
        if (poolExists[newPoolId]) {
            revert PoolErrors.PoolAlreadyExists(newPoolId);
        }

        // Set pool configuration
        pools[newPoolId].joiningFee = joiningFee;
        poolExists[newPoolId] = true;

        // Add the initial empty root (0) to history for the new pool.
        // LeanIMT's _insert functions handle initialisation implicitly on first insert.
        // We still add 0 here to mark the creation and ensure rootHistory is always consistent.
        _updateRootHistory(newPoolId, 0);

        emit PoolCreated(newPoolId, joiningFee);
    }

    /// @notice Internal function to add a single member to a pool.
    /// This is called by the derived contract's `addMember` implementation.
    /// @param poolId The ID of the pool.
    /// @param identityCommitment The identity commitment to add.
    function _addMember(
        uint256 poolId,
        uint256 identityCommitment
    ) internal returns (uint256 merkleTreeRoot) {
        // No explicit LeanIMTData initialization needed; _insert handles it.
        uint256 index = merkleTrees[poolId].size; // Get current size before insertion
        merkleTreeRoot = merkleTrees[poolId]._insert(identityCommitment);

        // Update root history with the new root
        uint32 merkleRootIndex = _updateRootHistory(poolId, merkleTreeRoot);

        // MemberAdded event from IPoolManager
        emit MemberAdded(
            poolId,
            index,
            identityCommitment,
            merkleTreeRoot,
            merkleRootIndex
        );
    }

    /// @notice Internal function to add multiple members to a pool.
    /// This is called by the derived contract's `addMembers` implementation.
    /// @param poolId The ID of the pool.
    /// @param identityCommitments Array of identity commitments to add.
    function _addMembers(
        uint256 poolId,
        uint256[] calldata identityCommitments
    ) internal returns (uint256 merkleTreeRoot) {
        // No explicit LeanIMTData initialization needed; _insertMany handles it.
        uint256 startIndex = merkleTrees[poolId].size; // Get current size before insertion
        merkleTreeRoot = merkleTrees[poolId]._insertMany(identityCommitments);

        // Update root history with the new root
        uint32 merkleRootIndex = _updateRootHistory(poolId, merkleTreeRoot);

        // MembersAdded event from IPoolManager
        emit MembersAdded(
            poolId,
            startIndex,
            identityCommitments,
            merkleTreeRoot,
            merkleRootIndex
        );
    }

    /// @notice Update root history with rolling window.
    function _updateRootHistory(
        uint256 poolId,
        uint256 merkleTreeRoot
    ) internal returns (uint32) {
        PoolConfig storage pool = pools[poolId];

        uint32 nextIndex;
        if (pool.rootHistoryCount == 0) {
            // First root goes to index 0
            nextIndex = 0;
        } else {
            // Subsequent roots follow circular buffer logic
            nextIndex =
                (pool.rootHistoryCurrentIndex + 1) %
                Constants.POOL_ROOT_HISTORY_SIZE;
        }

        pool.rootsHistory[nextIndex] = merkleTreeRoot;
        pool.rootHistoryCurrentIndex = nextIndex;

        // Increment count (but cap it at POOL_ROOT_HISTORY_SIZE)
        if (pool.rootHistoryCount < Constants.POOL_ROOT_HISTORY_SIZE) {
            pool.rootHistoryCount++;
        }
        return nextIndex;
    }

    /// @notice Add deposits to pool.
    function _addDeposits(uint256 poolId, uint256 amount) internal {
        pools[poolId].totalDeposits += amount;
    }

    /// @notice Reduce deposits from pool.
    function _reduceDeposits(uint256 poolId, uint256 amount) internal {
        uint256 totalDeposits = pools[poolId].totalDeposits;
        if (totalDeposits < amount) {
            revert PoolErrors.InsufficientDeposits(totalDeposits, amount);
        }
        pools[poolId].totalDeposits = totalDeposits - amount;
    }

    // ============ Public View Functions (Implementing IPoolManager) ============
    // These functions provide read-only access and are fully implemented here
    // as their logic is generic for any Merkle tree based pool.

    /// @inheritdoc IPoolManager
    function hasMember(
        uint256 poolId,
        uint256 identityCommitment
    ) public view override returns (bool) {
        // No need for onlyExistingPool here. If pool doesn't exist, merkleTrees[poolId]
        // will be default-initialized, and _has will correctly return false.
        return merkleTrees[poolId]._has(identityCommitment);
    }

    /// @inheritdoc IPoolManager
    function indexOf(
        uint256 poolId,
        uint256 identityCommitment
    ) public view override returns (uint256) {
        // Similar to hasMember, if pool doesn't exist, _indexOf will return 0 (default for not found).
        return merkleTrees[poolId]._indexOf(identityCommitment);
    }

    /// @inheritdoc IPoolManager
    function getMerkleTreeRoot(
        uint256 poolId
    ) public view override returns (uint256) {
        // If pool doesn't exist, this will return 0 (default root of empty tree)
        return merkleTrees[poolId]._root();
    }

    /// @inheritdoc IPoolManager
    function getMerkleTreeDepth(
        uint256 poolId
    ) public view override returns (uint256) {
        // If pool doesn't exist, this will return 0 (default depth of empty tree)
        return merkleTrees[poolId].depth;
    }

    /// @inheritdoc IPoolManager
    function getMerkleTreeSize(
        uint256 poolId
    ) public view override returns (uint256) {
        // If pool doesn't exist, this will return 0 (default size of empty tree)
        return merkleTrees[poolId].size;
    }

    /// @inheritdoc IPoolManager
    function getLatestValidRootInfo(
        uint256 poolId
    )
        public
        view
        override
        onlyExistingPool(poolId)
        returns (uint256 latestRoot, uint32 rootIndex)
    {
        latestRoot = merkleTrees[poolId]._root();
        rootIndex = pools[poolId].rootHistoryCurrentIndex;
    }

    /// @inheritdoc IPoolManager
    function getValidRootAtIndex(
        uint256 poolId,
        uint32 index
    ) public view override onlyExistingPool(poolId) returns (uint256 root) {
        PoolConfig storage pool = pools[poolId];
        // Only return if the index actually has a root in the recorded history count
        if (index >= pool.rootHistoryCount) {
            revert PoolErrors.MerkleRootNotInHistory(
                index,
                pool.rootHistoryCount
            );
        }
        return pool.rootsHistory[index];
    }

    /// @inheritdoc IPoolManager
    function getValidRoots(
        uint256 poolId
    )
        public
        view
        override
        onlyExistingPool(poolId)
        returns (uint32[] memory indices, uint256[] memory roots)
    {
        PoolConfig storage pool = pools[poolId];
        uint32 count = pool.rootHistoryCount;

        uint32 validCount = count > Constants.POOL_ROOT_HISTORY_SIZE
            ? Constants.POOL_ROOT_HISTORY_SIZE
            : count;

        indices = new uint32[](validCount);
        roots = new uint256[](validCount);

        if (count <= Constants.POOL_ROOT_HISTORY_SIZE) {
            for (uint32 i = 0; i < validCount; i++) {
                indices[i] = i;
                roots[i] = pool.rootsHistory[i];
            }
        } else {
            uint32 currentIndex = pool.rootHistoryCurrentIndex;
            for (uint32 i = 0; i < validCount; i++) {
                uint32 searchIndex = (currentIndex + 1 + i) %
                    Constants.POOL_ROOT_HISTORY_SIZE;
                indices[i] = searchIndex;
                roots[i] = pool.rootsHistory[searchIndex];
            }
        }
    }

    /// @inheritdoc IPoolManager
    function findRootIndex(
        uint256 poolId,
        uint256 merkleRoot
    )
        public
        view
        override
        onlyExistingPool(poolId)
        returns (uint32 index, bool found)
    {
        if (merkleRoot == 0) {
            return (type(uint32).max, false);
        }

        PoolConfig storage pool = pools[poolId];
        uint32 count = pool.rootHistoryCount;
        uint32 searchLimit = count > Constants.POOL_ROOT_HISTORY_SIZE
            ? Constants.POOL_ROOT_HISTORY_SIZE
            : count;

        if (count <= Constants.POOL_ROOT_HISTORY_SIZE) {
            for (uint32 i = 0; i < searchLimit; i++) {
                if (pool.rootsHistory[i] == merkleRoot) {
                    return (i, true);
                }
            }
        } else {
            uint32 currentIndex = pool.rootHistoryCurrentIndex;
            for (uint32 i = 0; i < searchLimit; i++) {
                uint32 searchIndex = (currentIndex + 1 + i) %
                    Constants.POOL_ROOT_HISTORY_SIZE;
                if (pool.rootsHistory[searchIndex] == merkleRoot) {
                    return (searchIndex, true);
                }
            }
        }

        return (type(uint32).max, false);
    }

    /// @inheritdoc IPoolManager
    function getPoolRootHistoryInfo(
        uint256 poolId
    )
        public
        view
        override
        onlyExistingPool(poolId)
        returns (uint32 currentIndex, uint32 historyCount, uint32 validCount)
    {
        PoolConfig storage pool = pools[poolId];
        currentIndex = pool.rootHistoryCurrentIndex;
        historyCount = pool.rootHistoryCount;
        validCount = historyCount > Constants.POOL_ROOT_HISTORY_SIZE
            ? Constants.POOL_ROOT_HISTORY_SIZE
            : historyCount;
    }

    function getJoiningFee(
        uint256 poolId
    ) public view onlyExistingPool(poolId) returns (uint256) {
        return pools[poolId].joiningFee;
    }

    function getPoolDeposits(
        uint256 poolId
    ) public view onlyExistingPool(poolId) returns (uint256) {
        return pools[poolId].totalDeposits;
    }
}
