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

1. **PrepaidGasPaymaster**: Main contract implementing the paymaster logic
2. **SemaphoreGroupManager**: Manages Semaphore groups and member operations
3. **BasePaymaster**: Base paymaster functionality from Account Abstraction
4. **ISemaphoreGasManager**: Interface defining the gas management functions

### Smart Contract Structure

```
PrepaidGasPaymaster
├── Group Management
│   ├── createGroup()
│   ├── addMember()
│   └── addMembers()
├── Proof Validation
│   ├── verifyProof()
│   └── _validateProof()
├── Paymaster Operations
│   ├── _validatePaymasterUserOp()
│   └── _postOp()
└── Utilities
    ├── _getMessageHash()
    └── _hash()
```

## Installation

```bash
npm install
```

## Development

### Prerequisites

- Node.js 18+
- Hardhat
- Viem
- Semaphore Protocol
- Docker and Docker Compose

### Environment Setup

Create a `.env` file with the following variables:

```env
PRIVATE_KEY=your_private_key
INFURA_API_KEY=your_infura_api_key
ETHERSCAN_API_KEY=your_etherscan_api_key
```

### Mock AA Environment Setup

Before running scripts, you need to set up the mock Account Abstraction environment:

```bash
# Navigate to the mock-aa-environment directory
cd ../mock-aa-environment

# Start the mock AA environment
docker compose up -d

# Verify the services are running
docker compose ps
```

This will start:
- Mock bundler service
- Local blockchain node

### Compilation

```bash
npx hardhat compile
```

### Testing

```bash
npx hardhat test
```

### Deployment

```bash
npx hardhat run scripts/deploy.ts --network <network>
```

## Usage

### 1. Deploy the Paymaster

```typescript
const paymaster = await hre.viem.deployContract(
  'PrepaidGasPaymaster',
  [entryPoint07Address, SEMAPHORE_VERIFIER],
  {
    libraries: {
      PoseidonT3: POSEIDON_T3,
    },
  }
);
```

### 2. Create a Group

```typescript
const joiningFee = parseEther('0.01');
await paymaster.write.createGroup([joiningFee]);
```

### 3. Add Members to Group

```typescript
// Generate identity from signature
const sig = await wallet.signMessage({ message: 'My Identity' });
const identity = new Identity(sig);

// Add member to group
await paymaster.write.addMember([groupId, identity.commitment], {
  value: joiningFee,
});
```

### 4. Generate and Use Proof

```typescript
// Generate Semaphore proof
const proof = await generateProof(identity, testGroup, message, groupId);

// Create user operation with paymaster data
const userOperation = {
  // ... user operation fields
  paymaster: paymaster.address,
  paymasterData: generatePaymasterData(groupId, proof),
};
```

## Contract Functions

### Group Management

- `createGroup(uint256 joiningFee)`: Create a new group with joining fee
- `createGroup(uint256 joiningFee, uint256 merkleTreeDuration)`: Create group with custom duration
- `addMember(uint256 groupId, uint256 identityCommitment)`: Add single member
- `addMembers(uint256 groupId, uint256[] identityCommitments)`: Add multiple members

### Proof Validation

- `verifyProof(uint256 groupId, SemaphoreProof proof)`: Verify a Semaphore proof
- `_validateProof(uint256 groupId, SemaphoreProof proof)`: Internal proof validation

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
cd ../mock-aa-environment && docker compose up -d
```

### End-to-End Demo
```bash
npx hardhat run scripts/anonymous-paymaster-e2e.ts
```

### Multi-Identity Demo
```bash
npx hardhat run scripts/multi-identity-e2e.ts
```

### Group Creation
```bash
npx hardhat run scripts/create-groups.ts
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


