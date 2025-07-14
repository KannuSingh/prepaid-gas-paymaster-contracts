# Prepaid Gas Paymaster

A privacy-preserving gas payment system built on Ethereum using Semaphore zero-knowledge proofs and Account Abstraction (ERC-4337).

## Overview

The Prepaid Gas Paymaster enables users to pay for gas fees anonymously using zero-knowledge proofs. Users join groups by depositing funds, then can spend gas credits without revealing their identity through Semaphore proofs.

## Key Features

- **Privacy-Preserving**: Users can pay gas fees without revealing their identity
- **Group-Based**: Users join groups by depositing funds and can spend from the group's balance
- **Zero-Knowledge Proofs**: Uses Semaphore protocol for anonymous authentication
- **Account Abstraction**: Compatible with ERC-4337 UserOperations
- **Gas Tracking**: Individual gas usage tracking per nullifier
- **Flexible Groups**: Configurable joining fees and Merkle tree durations

## Architecture

### Core Components

1. **GasLimitedPaymaster**: Paymaster with multi-use gas credits per pool member
2. **OneTimeUsePaymaster**: Paymaster with single-use gas credits per nullifier
3. **PrepaidGasPoolManager**: Manages privacy pools using Lean Incremental Merkle Trees
4. **BasePaymaster**: Base paymaster functionality from Account Abstraction (ERC-4337)

### Smart Contract Structure

```
BasePaymaster (ERC-4337 implementation)
└── PrepaidGasPoolManager (privacy pool management)
    ├── GasLimitedPaymaster (multi-use with gas limits)
    └── OneTimeUsePaymaster (single-use with nullifier tracking)

Key Functions:
├── Pool Management
│   ├── createPool()
│   ├── addMember()
│   └── addMembers()
├── Proof Validation
│   ├── verifyProof()
│   └── _validateProof()
├── Paymaster Operations
│   ├── _validatePaymasterUserOp()
│   └── _postOp()
└── Utilities
    ├── getMessageHash()
    └── getPaymasterStubData()
```

## Installation

```bash
npm install
```

## Development

### Prerequisites

- Node.js 18+
- Docker and Docker Compose
- Git

### Quick Start

1. **Clone and Install**
   ```bash
   git clone <repository-url>
   cd prepaid-gas-paymaster-contracts
   npm install
   ```

2. **Environment Setup** (Optional for local development)
   ```bash
   # Create .env file for testnet deployment only
   PRIVATE_KEY=your_private_key
   INFURA_API_KEY=your_infura_api_key
   ETHERSCAN_API_KEY=your_etherscan_api_key
   ```

3. **Start Mock AA Environment**
   ```bash
   cd mock-aa-environment
   docker compose up -d
   cd ..
   ```

4. **Compile Contracts**
   ```bash
   npx hardhat compile
   ```

5. **Run Tests**
   ```bash
   npx hardhat test
   ```

6. **Run Integration Tests**
   ```bash
   npx hardhat run scripts/integration-test.ts --network dev
   ```

### Mock AA Environment Details

The mock environment provides:
- **Anvil**: Local blockchain (forked from Base Sepolia)
- **Alto Bundler**: ERC-4337 bundler service on port 4337
- **Pre-deployed contracts**: EntryPoint, Verifier, and dependencies

Services:
- Blockchain: `http://localhost:8545`
- Bundler: `http://localhost:4337`

### Deployment Options

**Local Development:**
```bash
npx hardhat ignition deploy ignition/modules/PrepaidGasPaymaster.ts --network dev
```

**Base Sepolia Testnet:**
```bash
npx hardhat ignition deploy ignition/modules/PrepaidGasPaymaster.ts --network baseSepolia
```

## Usage

### 1. Deploy the Paymaster

```typescript
const paymaster = await hre.viem.deployContract(
  'GasLimitedPaymaster',
  [entryPoint07Address, SEMAPHORE_VERIFIER],
  {
    libraries: {
      PoseidonT3: POSEIDON_T3,
    },
  }
);
```

### 2. Create a Pool

```typescript
const joiningFee = parseEther('0.01');
await paymaster.write.createPool([joiningFee]);
```

### 3. Add Members to Pool

```typescript
// Generate identity from signature
const sig = await wallet.signMessage({ message: 'My Identity' });
const identity = new Identity(sig);

// Add member to pool
await paymaster.write.addMember([poolId, identity.commitment], {
  value: joiningFee,
});
```

### 4. Generate and Use Proof

```typescript
// Generate Semaphore proof
const proof = await generateProof(identity, testGroup, message, poolId);

// Create user operation with paymaster data
const userOperation = {
  // ... user operation fields
  paymaster: paymaster.address,
  paymasterData: generatePaymasterData(poolId, proof),
};
```

## Contract Functions

### Pool Management

- `createPool(uint256 joiningFee)`: Create a new pool with joining fee
- `addMember(uint256 poolId, uint256 identityCommitment)`: Add single member
- `addMembers(uint256 poolId, uint256[] identityCommitments)`: Add multiple members

### Proof Validation

- `verifyProof(DataLib.PoolMembershipProof calldata proof)`: Verify a Semaphore proof
- `_validateProof(DataLib.PoolMembershipProof memory proof)`: Internal proof validation

### Paymaster Operations

- `_validatePaymasterUserOp()`: Validate user operation with Semaphore proof
- `_postOp()`: Post-operation processing and gas deduction

## Data Structures

### GroupConfig
```solidity
struct GroupConfig {
    uint256 merkleTreeDuration;
    uint256 joiningFee;
    uint256 totalDeposits;
    mapping(uint256 => uint256) merkleRootCreationDates;
}
```

### SemaphoreProof
```solidity
struct SemaphoreProof {
    uint256 merkleTreeDepth;
    uint256 merkleTreeRoot;
    uint256 nullifier;
    uint256 message;
    uint256 scope;
    uint256[8] points;
}
```

### UserGasData
```solidity
struct UserGasData {
    uint256 gasUsed;
    uint256 lastMerkleRoot;
}
```

## Security Features

- **Nullifier Tracking**: Prevents double-spending of gas credits
- **Group Balance Checks**: Ensures sufficient funds for gas payments
- **Proof Validation**: Cryptographic verification of user membership
- **Gas Allowance Limits**: Per-user gas spending limits
- **Merkle Root Expiration**: Time-based validity of group states

## Networks Supported

- Ethereum Mainnet
- Base
- Base Sepolia
- Optimism
- Sepolia
- Local Development

## Testing

The project includes comprehensive tests covering:

- Contract deployment
- Group creation and management
- Member addition and updates
- Proof generation and validation
- Paymaster operations
- Gas tracking and limits
- Error conditions and edge cases

Run tests with:
```bash
npm test
```

## Scripts

**Note**: Before running any scripts, make sure the mock AA environment is running:
```bash
cd mock-aa-environment && docker compose up -d
```

### Integration Test (Multi-Wallet Validation)
Tests comprehensive multi-wallet scenarios with 3 different identities, unique smart accounts, and detailed validation checks. Best for verifying real-world usage patterns.

```bash
npx hardhat run scripts/integration-test.ts --network dev
```

### Stress Test (Performance & High Volume)
Runs 100 sequential transactions with performance metrics and proof generation timing. Best for testing system performance and gas optimization.

```bash
npx hardhat run scripts/stress-test.ts --network dev
```

### Pool Creation
Creates multiple pools with different joining fee tiers for testing various scenarios.

```bash
npx hardhat run tasks/create-pools.ts
```

## Dependencies

- `@account-abstraction/contracts`: ERC-4337 Account Abstraction
- `@semaphore-protocol/contracts`: Semaphore zero-knowledge protocol
- `@semaphore-protocol/core`: Semaphore core utilities
- `permissionless`: Permissionless account utilities
- `viem`: Ethereum client library

## Acknowledgments

- Semaphore Protocol team for the zero-knowledge proof infrastructure
- Account Abstraction community for ERC-4337 implementation
- [**Semaphore Paymaster**](https://github.com/semaphore-paymaster) for similar relevant work


