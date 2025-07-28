# Prepaid Gas Paymaster Contracts

Smart contracts for privacy-preserving gas payments using Semaphore zero-knowledge proofs and Account Abstraction (ERC-4337).

## Quick Start

```bash
# Install dependencies
npm install

# Start mock AA environment
cd mock-aa-environment && docker compose up -d

# Compile contracts
npx hardhat compile

# Deploy contracts
npx hardhat ignition deploy ignition/modules/PrepaidGasPaymaster.ts --network dev

# Run one-time-use paymaster integration test
npx hardhat run scripts/one-time-use-paymaster-integration-test.ts --network dev

# Run gas-limited paymaster integration test
npx hardhat run scripts/gas-limited-integration-test.ts --network dev

# Run cache-enabled gas limited paymaster-integration-test integration test
npx hardhat run scripts/cache-enabled-paymaster-integration-test.ts --network dev
```

## Contract Types

| Contract | Description |
|----------|-------------|
| **GasLimitedPaymaster** | Multi-use gas credits with usage limits per nullifier |
| **OneTimeUsePaymaster** | Single-use gas credits with nullifier tracking |
| **CacheEnabledGasLimitedPaymaster** | Optimized multi-use with smart caching |

## Architecture

```
BasePaymaster (ERC-4337)
└── PrepaidGasPool (privacy pools)
    └── State (Merkle tree management)
        ├── GasLimitedPaymaster
        ├── OneTimeUsePaymaster  
        └── CacheEnabledGasLimitedPaymaster
```

## Development

### Mock Environment
The Docker Compose setup provides:
- **Anvil blockchain**: `http://localhost:8545`
- **Alto bundler**: `http://localhost:4337`
- **Pre-deployed contracts**: EntryPoint, Verifier

### Commands
```bash
npx hardhat compile                    # Compile contracts

```

### Deployment
```bash
# Local development
npx hardhat ignition deploy ignition/modules/PrepaidGasPaymaster.ts --network dev

# Base Sepolia testnet
npx hardhat ignition deploy ignition/modules/PrepaidGasPaymaster.ts --network baseSepolia
```

## Dependencies

- `@account-abstraction/contracts` - ERC-4337 implementation
- `@semaphore-protocol/contracts` - Zero-knowledge proofs
- `@zk-kit/lean-imt.sol` - Incremental Merkle trees

## License

MIT


