import hre from 'hardhat';

async function main() {
  const cacheEnableGasLimitedPaymasterAddress = '0xfFE794611e59A987D8f13585248414d40a02Bb58';
  const gasLimitedPaymasterAddress = '0xDEc68496A556CeE996894ac2FDc9E43F39938e62';
  const oneTimeUsePaymasterAddress = '0x4DACA5b0a5d10853F84bB400C5232E4605bc14A0';

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
  const CACHE_ENABLED_GAS_LIMITED_PAYMASTER_JOINING_AMOUNT =
    await cacheEnableGasLimitedPaymaster.read.JOINING_AMOUNT();
  const GAS_LIMITED_PAYMASTER_JOINING_AMOUNT = await gasLimitedPaymaster.read.JOINING_AMOUNT();
  const ONE_TIME_USE_PAYMASTER_JOINING_AMOUNT = await oneTimeUsePaymaster.read.JOINING_AMOUNT();

  console.log(
    `CacheEnabledGasLimitedPaymaster SCOPE : ${CACHE_ENABLED_GAS_LIMITED_PAYMASTER_SCOPE}`
  );
  console.log(
    `CacheEnabledGasLimitedPaymaster JOINING_AMOUNT : ${CACHE_ENABLED_GAS_LIMITED_PAYMASTER_JOINING_AMOUNT}`
  );
  console.log(`GasLimitedPaymaster SCOPE : ${GAS_LIMITED_PAYMASTER_SCOPE}`);
  console.log(`GasLimitedPaymaster JOINING_AMOUNT : ${GAS_LIMITED_PAYMASTER_JOINING_AMOUNT}`);
  console.log(`OneTimeUSePaymaster SCOPE : ${ONE_TIME_USE_PAYMASTER_SCOPE}`);
  console.log(`OneTimeUSePaymaster JOINING_AMOUNT : ${ONE_TIME_USE_PAYMASTER_JOINING_AMOUNT}`);

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
