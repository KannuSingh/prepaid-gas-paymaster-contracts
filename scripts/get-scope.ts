import { Identity } from '@semaphore-protocol/core';
import hre from 'hardhat';

async function main() {
  const cacheEnableGasLimitedPaymasterAddress = '0x84184bC6943789C7C6303630cd3e878B54d5c2f7';
  const gasLimitedPaymasterAddress = '0x20f406AB21D2D8e998303e554546D868B6d36A60';
  const oneTimeUsePaymasterAddress = '0xBd3d3f86b811B4c3b177891b5d1bdDA1Dbfd561a';

  const cacheEnableGasLimitedPaymaster = await hre.viem.getContractAt(
    'contracts/implementation/CacheEnabledGasLimitedPaymaster.sol:CacheEnabledGasLimitedPaymaster',
    cacheEnableGasLimitedPaymasterAddress
  );
  const gasLimitedPaymaster = await hre.viem.getContractAt(
    'contracts/implementation/GasLimitedPaymaster.sol:GasLimitedPaymaster',
    gasLimitedPaymasterAddress
  );
  const oneTimeUsePaymaster = await hre.viem.getContractAt(
    'contracts/implementation/OneTimeUsePaymaster.sol:OneTimeUsePaymaster',
    oneTimeUsePaymasterAddress
  );

  const CACHE_ENABLED_GAS_LIMITED_PAYMASTER_SCOPE =
    await cacheEnableGasLimitedPaymaster.read.SCOPE();
  const GAS_LIMITED_PAYMASTER_SCOPE = await gasLimitedPaymaster.read.SCOPE();
  const ONE_TIME_USE_PAYMASTER_SCOPE = await oneTimeUsePaymaster.read.SCOPE();

  console.log(
    `CacheEnabledGasLimitedPaymaster SCOPE : ${CACHE_ENABLED_GAS_LIMITED_PAYMASTER_SCOPE}`
  );
  console.log(`GasLimitedPaymaster SCOPE : ${GAS_LIMITED_PAYMASTER_SCOPE}`);
  console.log(`OneTimeUSePaymaster SCOPE : ${ONE_TIME_USE_PAYMASTER_SCOPE}`);

  // const [wallet1] = await hre.viem.getWalletClients();

  // let currentIdentity = new Identity(await wallet1.signMessage({ message: `identity-1` }));
  // await cacheEnableGasLimitedPaymaster.write.deposit([currentIdentity.commitment], {
  //   value: await cacheEnableGasLimitedPaymaster.read.JOINING_AMOUNT(),
  // });
  // await new Promise((resolve) => setTimeout(resolve, 2000));
  // await gasLimitedPaymaster.write.deposit([currentIdentity.commitment], {
  //   value: await gasLimitedPaymaster.read.JOINING_AMOUNT(),
  // });
  // await new Promise((resolve) => setTimeout(resolve, 2000));
  // await oneTimeUsePaymaster.write.deposit([currentIdentity.commitment], {
  //   value: await oneTimeUsePaymaster.read.JOINING_AMOUNT(),
  // });
  // console.log(`Deposit Completed!!!`);
}

main().catch((err) => {
  console.error('💥 Script failed:', err);
  process.exit(1);
});
