// file:prepaid-gas-paymaster-contracts/utils/generalUtils.ts

/**
 * Utility function to create a delay
 * @param ms Milliseconds to delay
 * @returns Promise that resolves after the specified delay
 */
export async function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}