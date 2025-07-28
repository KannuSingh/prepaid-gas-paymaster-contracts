// file:prepaid-gas-paymaster-contracts/utils/paymasterUtils.ts

import { concat, encodeAbiParameters, Hex, numberToHex } from 'viem';

interface ProofData {
  merkleTreeDepth: bigint;
  merkleTreeRoot: bigint;
  nullifier: bigint;
  message: bigint;
  scope: bigint;
  points: [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint];
}

/**
 * Generate paymaster data for ZK proof validation
 * @param merkleRootIndex Index of the merkle root in history
 * @param proof ZK proof data structure
 * @returns Encoded paymaster data as Hex
 */
export async function generatePaymasterData(
  merkleRootIndex: number | bigint,
  proof: ProofData
): Promise<Hex> {
  const VALIDATION_MODE = 0;
  const config = BigInt(merkleRootIndex) | (BigInt(VALIDATION_MODE) << 32n);
  const configBytes = numberToHex(config, { size: 32 });

  const proofBytes = encodeAbiParameters(
    [{
      type: 'tuple',
      components: [
        { name: 'merkleTreeDepth', type: 'uint256' },
        { name: 'merkleTreeRoot', type: 'uint256' },
        { name: 'nullifier', type: 'uint256' },
        { name: 'message', type: 'uint256' },
        { name: 'scope', type: 'uint256' },
        { name: 'points', type: 'uint256[8]' },
      ],
    }],
    [proof]
  );

  return concat([configBytes, proofBytes]);
}