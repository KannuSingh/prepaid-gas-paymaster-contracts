// file:prepaid-gas-paymaster-contracts/utils/contractTypes.ts

import { Address, Hash } from 'viem';

export interface PaymasterContract {
  address: Address;
  read: {
    currentRootIndex(): Promise<number>;
    currentRoot(): Promise<bigint>;
    currentTreeSize(): Promise<bigint>;
    totalDeposit(): Promise<bigint>;
    getDeposit(): Promise<bigint>;
  };
  write: {
    deposit(args: [bigint], options: { value: bigint }): Promise<Hash>;
  };
}

export interface CacheEnabledGasLimitedPaymasterContract extends Omit<PaymasterContract, 'read'> {
  read: PaymasterContract['read'] & {
    userNullifiersStates(args: [Address]): Promise<bigint>;
    userNullifiers(args: [Hash]): Promise<bigint>;
  };
}
export interface GasLimitedPaymasterContract extends Omit<PaymasterContract, 'read'> {
  read: PaymasterContract['read'] & {
    nullifierGasUsage(args: [bigint]): Promise<bigint>;
  };
}

export interface OneTimeUsePaymasterContract extends Omit<PaymasterContract, 'read'> {
  read: PaymasterContract['read'] & {
    usedNullifiers(args: [bigint]): Promise<boolean>;
  };
}

// Wallet client interface from Hardhat/Viem
export interface WalletClient {
  signMessage(args: { message: string }): Promise<Hash>;
  address?: Address;
  [key: string]: any; // Allow additional properties from viem wallet client
}

// Transaction receipt interface
export interface TransactionReceipt {
  success: boolean;
  actualGasUsed: bigint;
  actualGasCost: bigint;
  [key: string]: any; // Allow additional properties from viem receipt
}

// Stub data return type
export interface StubDataResult {
  paymasterData: `0x${string}`;
  paymasterPostOpGasLimit: bigint;
}

// Validation data return type
export interface ValidationDataResult {
  paymasterData: `0x${string}`;
}

// Cache availability result
export interface CacheAvailabilityResult {
  willUseCache: boolean;
  totalAvailable: bigint;
  gasThreshold: bigint;
}
