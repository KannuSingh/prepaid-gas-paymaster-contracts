import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox-viem';
import '@nomicfoundation/hardhat-ignition-viem';
import '@nomicfoundation/hardhat-verify';
import { NetworksUserConfig } from 'hardhat/types';
import { config as dotenvConfig } from 'dotenv';
import { resolve } from 'path';
import './tasks/create-pools';

dotenvConfig({ path: resolve(__dirname, './.env') });

const etherscanApiKey = process.env.ETHERSCAN_API_KEY;

function getNetworks(): NetworksUserConfig {
  const networks: NetworksUserConfig = {
    dev: {
      url: 'http://localhost:8545',
      chainId: 1, // Standard Hardhat Network chainId
      // accounts: You can omit accounts for local development if not using specific private keys,
      // as Hardhat's built-in accounts will be used by default.
    },
    localhost: {
      // Adding an explicit localhost entry, though 'dev' already points to it
      url: 'http://localhost:8545',
      chainId: 31337, // Common chainId for Hardhat Network
      // accounts: Same as dev, can be omitted
    },
  };

  if (process.env.INFURA_API_KEY && process.env.PRIVATE_KEY) {
    const accounts = [`0x${process.env.PRIVATE_KEY}`];
    networks.sepolia = {
      url: `https://sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`,
      chainId: 11155111,
      accounts,
    };
    networks.baseSepolia = {
      url: 'https://sepolia.base.org',
      chainId: 84532,
      accounts,
    };
    networks.base = {
      url: 'https://mainnet.base.org',
      chainId: 8453,
      accounts,
    };
    networks.optimism = {
      url: 'https://mainnet.optimism.io',
      chainId: 10,
      accounts,
    };
  }

  return networks;
}
const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        // For development and testing
        version: '0.8.24',
        settings: {
          optimizer: { enabled: true, runs: 200 },
        },
      },
    ],
  },
  networks: {
    hardhat: {
      chainId: 1337,
    },
    ...getNetworks(),
  },
  etherscan: {
    // Your API key for Etherscan
    // Obtain one at https://etherscan.io/
    apiKey: {
      baseSepolia: etherscanApiKey || '64ABH8BSJYIJQHB1VRG418XYSXB5S9X8QP',
      'base-sepolia': etherscanApiKey || '64ABH8BSJYIJQHB1VRG418XYSXB5S9X8QP',
    },
    customChains: [
      {
        chainId: 84532,
        network: 'base-sepolia',
        urls: {
          apiURL: 'https://api.etherscan.io/v2/api?chainid=84532',
          browserURL: 'https://sepolia.basescan.org',
        },
      },
    ],
  },
  sourcify: {
    enabled: true,
  },
  ignition: {
    strategyConfig: {
      create2: {
        // To learn more about salts, see the CreateX documentation
        salt: '0x0201202500000000000000000000000000000000000000000000000016121994',
      },
    },
  },
  paths: {
    sources: './contracts',
    artifacts: './artifacts',
  },
};

export default config;
