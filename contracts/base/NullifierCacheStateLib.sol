// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Utility library for encoding/decoding nullifier flags into a uint256
/// @dev Layout: activatedNullifierCount(8) | exhaustedSlotIndex(8) | hasAvailableExhaustedSlot(1) | activeNullifierIndex(8) | reserved(227)
library NullifierCacheStateLib {
    // === Encoding ===
    function encodeFlags(
        uint8 activatedNullifierCount,
        uint8 exhaustedSlotIndex,
        bool hasAvailableExhaustedSlot,
        uint8 activeNullifierIndex
    ) internal pure returns (uint256 flags) {
        flags =
            uint256(activatedNullifierCount) |
            (uint256(exhaustedSlotIndex) << 8) |
            (hasAvailableExhaustedSlot ? (1 << 16) : 0) |
            (uint256(activeNullifierIndex) << 17);
    }

    // === Decoding ===
    function getActivatedNullifierCount(
        uint256 flags
    ) internal pure returns (uint8) {
        return uint8(flags);
    }

    function getExhaustedSlotIndex(
        uint256 flags
    ) internal pure returns (uint8) {
        return uint8(flags >> 8);
    }

    function getHasAvailableExhaustedSlot(
        uint256 flags
    ) internal pure returns (bool) {
        return (flags >> 16) & 1 != 0;
    }

    function getActiveNullifierIndex(
        uint256 flags
    ) internal pure returns (uint8) {
        return uint8(flags >> 17);
    }

    // === Mutations ===
    function setActivatedNullifierCount(
        uint256 flags,
        uint8 value
    ) internal pure returns (uint256) {
        return (flags & ~(uint256(0xFF))) | uint256(value);
    }

    function setExhaustedSlotIndex(
        uint256 flags,
        uint8 value
    ) internal pure returns (uint256) {
        return (flags & ~(uint256(0xFF) << 8)) | (uint256(value) << 8);
    }

    function setHasAvailableExhaustedSlot(
        uint256 flags,
        bool value
    ) internal pure returns (uint256) {
        return value ? (flags | (1 << 16)) : (flags & ~(uint256(1) << 16));
    }

    function setActiveNullifierIndex(
        uint256 flags,
        uint8 value
    ) internal pure returns (uint256) {
        return (flags & ~(uint256(0xFF) << 17)) | (uint256(value) << 17);
    }

    // === Convenience Functions ===
    function incrementActivatedCount(
        uint256 flags
    ) internal pure returns (uint256) {
        uint8 currentCount = getActivatedNullifierCount(flags);
        return setActivatedNullifierCount(flags, currentCount + 1);
    }

    function decrementActivatedCount(
        uint256 flags
    ) internal pure returns (uint256) {
        uint8 currentCount = getActivatedNullifierCount(flags);
        return setActivatedNullifierCount(flags, currentCount - 1);
    }

    function advanceActiveIndex(uint256 flags) internal pure returns (uint256) {
        uint8 currentIndex = getActiveNullifierIndex(flags);
        uint8 nextIndex = (currentIndex + 1) % 2; // Wrap around for 2 slots
        return setActiveNullifierIndex(flags, nextIndex);
    }

    function markSlotAsExhausted(
        uint256 flags,
        uint8 slotIndex
    ) internal pure returns (uint256) {
        flags = setExhaustedSlotIndex(flags, slotIndex);
        flags = setHasAvailableExhaustedSlot(flags, true);
        flags = decrementActivatedCount(flags);
        // Advance active index to next slot when current one is exhausted
        uint8 currentActiveIndex = getActiveNullifierIndex(flags);
        if (currentActiveIndex == slotIndex) {
            flags = advanceActiveIndex(flags);
        }
        return flags;
    }

    function reuseExhaustedSlot(uint256 flags) internal pure returns (uint256) {
        flags = setHasAvailableExhaustedSlot(flags, false);
        flags = incrementActivatedCount(flags);
        return flags;
    }

    /// @notice Initialize state for first nullifier
    function initializeFirstNullifier(
        uint256 flags
    ) internal pure returns (uint256) {
        flags = setActivatedNullifierCount(flags, 1);
        flags = setActiveNullifierIndex(flags, 0); // Start consuming from slot 0
        flags = setHasAvailableExhaustedSlot(flags, false); // Clear exhausted state
        return flags;
    }

    /// @notice Add second nullifier (both slots now active)
    function addSecondNullifier(uint256 flags) internal pure returns (uint256) {
        flags = setActivatedNullifierCount(flags, 2);
        // Keep current activeNullifierIndex as is
        return flags;
    }
}
