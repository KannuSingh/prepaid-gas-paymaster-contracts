import hre from 'hardhat';
import { parseEther } from 'viem';
import { entryPoint07Address } from 'viem/account-abstraction';

async function main() {
  const cacheEnableGasLimitedPaymasterAddress = '0x67A9Ed5F51d8Eb2ceA70075B0554a9c2F21E8708';
  const gasLimitedPaymasterAddress = '0xA1c868aD7fae4159f07493df22E5004aaDb5467D';
  const oneTimeUsePaymasterAddress = '0xF003a8C423691dCFB35Ac54e2fB6a7B1AE3185bf';

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
}

main().catch((err) => {
  console.error('💥 Script failed:', err);
  process.exit(1);
});
