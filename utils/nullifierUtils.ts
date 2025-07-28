// file:prepaid-gas-paymaster-contracts/utils/nullifierUtils.ts

export interface NullifierState {
  activatedNullifierCount: number;
  exhaustedSlotIndex: number;
  hasAvailableExhaustedSlot: boolean;
}

/**
 * Decode nullifier state flags from packed uint256 value
 * @param flags Packed state flags from contract
 * @returns Decoded nullifier state
 */
export function decodeNullifierState(flags: bigint): NullifierState {
  return {
    activatedNullifierCount: Number(flags & 0xffn),
    exhaustedSlotIndex: Number((flags >> 8n) & 0xffn),
    hasAvailableExhaustedSlot: ((flags >> 16n) & 1n) !== 0n,
  };
}