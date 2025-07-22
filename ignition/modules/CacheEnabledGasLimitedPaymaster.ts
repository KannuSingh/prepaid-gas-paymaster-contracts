import { buildModule } from '@nomicfoundation/hardhat-ignition/modules';
import { parseEther } from 'viem';

const ENTRYPOINT_V7 = '0x0000000071727De22E5E9d8BAf0edAc6f37da032';
const SEMAPHORE_VERIFIER = '0x6C42599435B82121794D835263C846384869502d';
const POSEIDON_T3 = '0xB43122Ecb241DD50062641f089876679fd06599a';

const CacheEnabledGasLimitedPaymasterModule_1 = buildModule(
  'CacheEnabledGasLimitedPaymasterModule',
  (m) => {
    const entryPoint = m.getParameter('entryPoint', ENTRYPOINT_V7);
    const semaphoreVerifier = m.getParameter('semaphoreVerifier', SEMAPHORE_VERIFIER);

    const poseidonT3 = m.contractAt('PoseidonT3', POSEIDON_T3);

    const joiningAmount = parseEther('0.001');
    const cacheEnabledGasLimitedPaymaster = m.contract(
      'CacheEnabledGasLimitedPaymaster',
      [joiningAmount, entryPoint, semaphoreVerifier],
      {
        libraries: {
          PoseidonT3: poseidonT3,
        },
      }
    );

    return { cacheEnabledGasLimitedPaymaster };
  }
);

export default CacheEnabledGasLimitedPaymasterModule_1;
