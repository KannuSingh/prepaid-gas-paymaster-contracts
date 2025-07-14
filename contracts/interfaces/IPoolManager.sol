// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPoolManager
/// @notice Interface for contracts that manage privacy pools (e.g., Merkle tree-based pools)
interface IPoolManager {
    // ============ Events ============
    // Removed merkleTreeDuration from PoolCreated event
    event PoolCreated(uint256 indexed poolId, uint256 joiningFee);
    event MemberAdded(
        uint256 indexed poolId,
        uint256 indexed memberIndex,
        uint256 indexed identityCommitment,
        uint256 merkleTreeRoot,
        uint32 merkleRootIndex
    );
    event MembersAdded(
        uint256 indexed poolId,
        uint256 startIndex,
        uint256[] identityCommitments,
        uint256 merkleTreeRoot,
        uint32 merkleRootIndex
    );

    // ============ Admin/Management Functions ============
    // These functions create and modify the pool state.
    // They are external and meant to be called by authorized entities.

    /// @notice Creates a new prepaid gas pool with specified joining fee.
    /// @param joiningFee The fee required to join this pool.
    /// @return poolId The ID of the newly created pool.
    function createPool(uint256 joiningFee) external returns (uint256 poolId);

    /// @notice Adds a single member to a pool.
    /// Requires payment of the joining fee via `msg.value`.
    /// @param poolId The ID of the pool.
    /// @param identityCommitment The identity commitment of the member to add.
    function addMember(
        uint256 poolId,
        uint256 identityCommitment
    ) external payable returns (uint256);

    /// @notice Adds multiple members to a pool.
    /// Requires payment of `memberCount * joiningFee` via `msg.value`.
    /// @param poolId The ID of the pool.
    /// @param identityCommitments Array of identity commitments of members to add.
    function addMembers(
        uint256 poolId,
        uint256[] calldata identityCommitments
    ) external payable returns (uint256);

    // ============ Public View Functions ============
    // These functions query the state of the pool.

    /// @notice Checks if a pool exists.
    /// @param poolId The ID of the pool.
    /// @return True if the pool exists, false otherwise.
    function poolExists(uint256 poolId) external view returns (bool);

    /// @notice Checks if an identity commitment is a member of a pool.
    /// @param poolId The ID of the pool.
    /// @param identityCommitment The identity commitment to check.
    /// @return True if the identity commitment is a member, false otherwise.
    function hasMember(
        uint256 poolId,
        uint256 identityCommitment
    ) external view returns (bool);

    /// @notice Gets the index of an identity commitment in a pool's Merkle tree.
    /// @param poolId The ID of the pool.
    /// @param identityCommitment The identity commitment to find.
    /// @return The index of the commitment, or a specific value (e.g., 0 for LeanIMT if not found, or max uint256) if not found.
    function indexOf(
        uint256 poolId,
        uint256 identityCommitment
    ) external view returns (uint256);

    /// @notice Gets the current Merkle tree root for a pool.
    /// @param poolId The ID of the pool.
    /// @return The current Merkle root.
    function getMerkleTreeRoot(uint256 poolId) external view returns (uint256);

    /// @notice Gets the depth of the Merkle tree for a pool.
    /// @param poolId The ID of the pool.
    /// @return The depth of the Merkle tree.
    function getMerkleTreeDepth(uint256 poolId) external view returns (uint256);

    /// @notice Gets the size (number of leaves) of the Merkle tree for a pool.
    /// @param poolId The ID of the pool.
    /// @return The current size of the Merkle tree.
    function getMerkleTreeSize(uint256 poolId) external view returns (uint256);

    /// @notice Gets the latest Merkle tree root and its current index in the history for a pool.
    /// @param poolId The ID of the pool.
    /// @return latestRoot The latest Merkle root.
    /// @return rootIndex The index of the latest root in the circular history buffer.
    function getLatestValidRootInfo(
        uint256 poolId
    ) external view returns (uint256 latestRoot, uint32 rootIndex);

    /// @notice Gets a root from the history by its index for a pool.
    /// @param poolId The ID of the pool.
    /// @param index The index in the root history (0 to POOL_ROOT_HISTORY_SIZE-1).
    /// @return The merkle root at that index, or 0 if invalid or not yet filled.
    function getValidRootAtIndex(
        uint256 poolId,
        uint32 index
    ) external view returns (uint256);

    /// @notice Gets all valid root indices and their corresponding roots from the history for a pool.
    /// Roots are returned in chronological order from oldest to newest within the history buffer.
    /// @param poolId The ID of the pool.
    /// @return indices Array of valid indices in the root history.
    /// @return roots Array of corresponding merkle roots.
    function getValidRoots(
        uint256 poolId
    ) external view returns (uint32[] memory indices, uint256[] memory roots);

    /// @notice Finds the index of a specific Merkle root in the history for a pool.
    /// @param poolId The ID of the pool.
    /// @param merkleRoot The merkle root to find.
    /// @return index The index of the root, or type(uint32).max if not found.
    /// @return found Whether the root was found in valid history.
    function findRootIndex(
        uint256 poolId,
        uint256 merkleRoot
    ) external view returns (uint32 index, bool found);

    /// @notice Gets information about a pool's root history.
    /// @param poolId The ID of the pool.
    /// @return currentIndex The current index in the circular buffer.
    /// @return historyCount Total number of roots ever added (not capped by buffer size).
    /// @return validCount Number of currently valid roots (capped by POOL_ROOT_HISTORY_SIZE).
    function getPoolRootHistoryInfo(
        uint256 poolId
    )
        external
        view
        returns (uint32 currentIndex, uint32 historyCount, uint32 validCount);
}
