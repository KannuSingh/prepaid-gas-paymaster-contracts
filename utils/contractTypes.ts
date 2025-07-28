// file:prepaid-gas-paymaster-contracts/utils/contractTypes.ts

import { Address, Hash } from 'viem';

export interface PaymasterContract {
  address: Address;
  read: {
    currentRootIndex(): Promise<number>;
    currentRoot(): Promise<bigint>;
    currentTreeSize(): Promise<bigint>;
    currentTreeDepth(): Promise<bigint>;
    totalDeposit(): Promise<bigint>;
    getDeposit(): Promise<bigint>;
    getRevenue(): Promise<bigint>;
    SCOPE(): Promise<bigint>;
    JOINING_AMOUNT(): Promise<bigint>;
    dead(): Promise<boolean>;
    roots(args: [bigint]): Promise<bigint>;
    [key: string]: any; // Allow additional contract methods
  };
  write: {
    deposit(args: [bigint], options: { value: bigint }): Promise<Hash>;
    [key: string]: any; // Allow additional contract methods
  };
  [key: string]: any; // Allow additional properties
}

export interface CacheEnabledGasLimitedPaymasterContract extends PaymasterContract {
  read: PaymasterContract['read'] & {
    userNullifiersStates(args: [Address]): Promise<bigint>;
    userNullifiers(args: [Hash]): Promise<bigint>;
    nullifierGasUsage(args: [bigint]): Promise<bigint>;
  };
}

export interface GasLimitedPaymasterContract extends PaymasterContract {
  read: PaymasterContract['read'] & {
    nullifierGasUsage(args: [bigint]): Promise<bigint>;
  };
}

export interface OneTimeUsePaymasterContract extends PaymasterContract {
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
