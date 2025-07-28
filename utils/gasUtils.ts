// file:prepaid-gas-paymaster-contracts/utils/gasUtils.ts

import { parseEther } from 'viem';

export interface GasConsumptionData {
  transaction: number;
  gasUsed: number;
  actualGasCost: number;
  isZKProof: boolean;
  isCached: boolean;
  phase: string;
}

/**
 * Calculate cached gas threshold based on historical gas consumption data
 * @param gasConsumption Array of gas consumption data
 * @returns Gas threshold as bigint
 */
export function calculateCachedGasThreshold(gasConsumption: GasConsumptionData[]): bigint {
  const cachedTransactions = gasConsumption.filter((tx) => tx.isCached && tx.actualGasCost);

  if (cachedTransactions.length === 0) {
    const zkProofTransactions = gasConsumption.filter((tx) => tx.isZKProof && tx.actualGasCost);
    if (zkProofTransactions.length > 0) {
      const lastZKCost = zkProofTransactions[zkProofTransactions.length - 1].actualGasCost;
      return BigInt(lastZKCost);
    }
    return parseEther('0.003');
  }

  const avgCachedCost =
    cachedTransactions.reduce((sum, tx) => sum + tx.actualGasCost, 0) / cachedTransactions.length;

  return (BigInt(Math.round(avgCachedCost)) * 200n) / 100n;
}