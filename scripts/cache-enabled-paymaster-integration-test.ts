import hre from 'hardhat';
import {
  concat,
  encodeAbiParameters,
  Hex,
  http,
  parseAbiParameters,
  parseEther,
  numberToHex,
  toHex,
  hexToString,
  keccak256,
  formatEther,
  encodePacked,
  PublicClient,
} from 'viem';
import { Identity, Group, generateProof } from '@semaphore-protocol/core';
import {
  BundlerClient,
  createBundlerClient,
  entryPoint07Address,
  GetPaymasterDataParameters,
  GetPaymasterStubDataParameters,
  SmartAccount,
  UserOperation,
} from 'viem/account-abstraction';
import { toSimpleSmartAccount } from 'permissionless/accounts';
import { getPackedUserOperation } from 'permissionless/utils';
import { createSmartAccountClient } from 'permissionless';
import { getMessageHash } from '../utils/getMessageHash';
import { getScope } from '../utils/getScope';
import { decodeNullifierState, type NullifierState } from '../utils/nullifierUtils';
import { calculateCachedGasThreshold, type GasConsumptionData } from '../utils/gasUtils';
import { delay } from '../utils/generalUtils';
import { generatePaymasterData } from '../utils/paymasterUtils';
import {
  type CacheEnabledGasLimitedPaymasterContract,
  type WalletClient,
  type TransactionReceipt,
  type StubDataResult,
  type ValidationDataResult,
  type CacheAvailabilityResult,
} from '../utils/contractTypes';

// ============ CONFIGURATION CONSTANTS ============
const CONFIG = {
  JOINING_AMOUNT: parseEther('0.01'),
  PAYMASTER_LIBRARIES: { PoseidonT3: '0xB43122Ecb241DD50062641f089876679fd06599a' },
  SEMAPHORE_VERIFIER: '0x6C42599435B82121794D835263C846384869502d',
  BUNDLER_URL: 'http://localhost:4337',
  DUMMY_TARGET: '0xF892dc5bBef591D61dD6d75Dfc963c371E723bA4',
  DUMMY_DATA: '0xdeedbeed',
  MAX_CONSECUTIVE_FAILURES: 3,
  MAX_TOTAL_TRANSACTIONS: 3,
  DELAY_MS: 2000,
  GAS_LIMITS: {
    CACHED_POSTOP: 45000n,
    ACTIVATION_POSTOP: 86650n,
  },
  PAYMASTER_MODES: {
    VALIDATION: 0,
    ESTIMATION: 1,
  },
} as const;

// ============ TYPE DEFINITIONS ============

interface TestState {
  identities: Identity[];
  successfulTransactions: number[];
  failedTransactions: number[];
  proofGenerationTimes: number[];
  gasConsumption: GasConsumptionData[];
  localPool: Group;
  currentIdentity: Identity;
  currentPhase: string;
  consecutiveFailures: number;
}

// ============ UTILITY FUNCTIONS ============

// ============ CONTRACT INTERACTION FUNCTIONS ============
async function deployPaymaster(): Promise<CacheEnabledGasLimitedPaymasterContract> {
  console.log('🚀 Deploying CacheEnabledGasLimitedPaymaster...');

  const paymaster = (await hre.viem.deployContract(
    'contracts/implementation/CacheEnabledGasLimitedPaymaster.sol:CacheEnabledGasLimitedPaymaster',
    [CONFIG.JOINING_AMOUNT, entryPoint07Address, CONFIG.SEMAPHORE_VERIFIER],
    { libraries: CONFIG.PAYMASTER_LIBRARIES }
  )) as CacheEnabledGasLimitedPaymasterContract;

  console.log(`   Deployed at: ${paymaster.address}`);
  return paymaster;
}

async function initializePool(
  paymaster: CacheEnabledGasLimitedPaymasterContract,
  wallet: WalletClient
): Promise<Group> {
  console.log('🏊 Initializing pool with dummy identities...');

  const dummyId = new Identity(await wallet.signMessage({ message: 'dummy' }));
  const dummyId2 = new Identity(await wallet.signMessage({ message: 'dummy2' }));
  const localPool = new Group([dummyId.commitment, dummyId2.commitment]);

  await delay(CONFIG.DELAY_MS);
  await paymaster.write.deposit([dummyId.commitment], { value: CONFIG.JOINING_AMOUNT });
  await delay(CONFIG.DELAY_MS);
  await paymaster.write.deposit([dummyId2.commitment], { value: CONFIG.JOINING_AMOUNT });

  return localPool;
}

async function addNewIdentity(
  paymaster: CacheEnabledGasLimitedPaymasterContract,
  wallet: WalletClient,
  identityCount: number,
  localPool: Group
): Promise<Identity> {
  console.log(`💰 Adding new identity to pool (identity-${identityCount})...`);

  const newIdentity = new Identity(
    await wallet.signMessage({ message: `identity-${identityCount}` })
  );

  await delay(CONFIG.DELAY_MS);
  await paymaster.write.deposit([newIdentity.commitment], { value: CONFIG.JOINING_AMOUNT });
  await delay(CONFIG.DELAY_MS);

  localPool.addMember(newIdentity.commitment);
  console.log('   Identity added to pool');

  return newIdentity;
}

// ============ STATE DISPLAY FUNCTIONS ============
async function displayNullifierState(
  paymaster: CacheEnabledGasLimitedPaymasterContract,
  smartAccountAddress: `0x${string}`,
  transactionNum: number
): Promise<void> {
  console.log('Smart Contract Address:', smartAccountAddress);
  const userNullifiersState = await paymaster.read.userNullifiersStates([smartAccountAddress]);
  const decodedState = decodeNullifierState(userNullifiersState);

  console.log(`\n📊 Nullifier State After Transaction ${transactionNum}:`);
  console.log(`   Active count: ${decodedState.activatedNullifierCount}`);
  console.log(`   Has exhausted slot: ${decodedState.hasAvailableExhaustedSlot}`);
  console.log(`   Exhausted slot index: ${decodedState.exhaustedSlotIndex}`);

  for (let j = 0; j < 2; j++) {
    const nullifierKey = keccak256(
      encodeAbiParameters(parseAbiParameters('address, uint8'), [smartAccountAddress, j])
    );
    const nullifier = await paymaster.read.userNullifiers([nullifierKey]);
    if (nullifier > 0n) {
      const used = await paymaster.read.nullifierGasUsage([nullifier]);
      const available = CONFIG.JOINING_AMOUNT > used ? CONFIG.JOINING_AMOUNT - used : 0n;
      console.log(
        `   Slot ${j}: ${nullifier.toString().slice(0, 12)}..., used: ${formatEther(used)} ETH, available: ${formatEther(available)} ETH`
      );
    } else {
      console.log(`   Slot ${j}: EMPTY`);
    }
  }
}

// ============ PAYMASTER CLIENT FUNCTIONS ============
async function createCachedStubData(): Promise<StubDataResult> {
  const cachedStubData = encodePacked(['uint8'], [CONFIG.PAYMASTER_MODES.ESTIMATION]);
  console.log(`   Stub data: ${cachedStubData.length} bytes (CACHED - self-generated)`);

  return {
    paymasterData: cachedStubData,
    paymasterPostOpGasLimit: CONFIG.GAS_LIMITS.CACHED_POSTOP,
  };
}

async function createZKStubData(
  paymaster: CacheEnabledGasLimitedPaymasterContract,
  publicClient: PublicClient
): Promise<StubDataResult> {
  const currentRootIndex = await paymaster.read.currentRootIndex();
  const config = BigInt(currentRootIndex) | (BigInt(CONFIG.PAYMASTER_MODES.ESTIMATION) << 32n);
  const currentRoot = await paymaster.read.currentRoot();
  const configBytes = numberToHex(config, { size: 32 });
  const scope = await paymaster.read.SCOPE(); // Read scope from contract

  const dummyProofBytes = encodeAbiParameters(
    [
      {
        name: 'proof',
        type: 'tuple',
        components: [
          { name: 'merkleTreeDepth', type: 'uint256' },
          { name: 'merkleTreeRoot', type: 'uint256' },
          { name: 'nullifier', type: 'uint256' },
          { name: 'message', type: 'uint256' },
          { name: 'scope', type: 'uint256' },
          { name: 'points', type: 'uint256[8]' },
        ],
      },
    ],
    [
      {
        merkleTreeDepth: 1n,
        merkleTreeRoot: currentRoot,
        nullifier: 0n,
        message: 0n,
        scope: scope,
        points: [0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n],
      },
    ]
  );

  const zkStubData = concat([configBytes, dummyProofBytes]);
  console.log(`   Stub data: ${zkStubData.length} bytes (ZK PROOF - self-generated)`);

  return {
    paymasterData: zkStubData,
    paymasterPostOpGasLimit: CONFIG.GAS_LIMITS.ACTIVATION_POSTOP,
  };
}

async function createCachedValidationData(): Promise<ValidationDataResult> {
  console.log(`   🚀 Using CACHED validation path`);
  const cachedData = encodePacked(['uint8'], [CONFIG.PAYMASTER_MODES.VALIDATION]);
  return { paymasterData: cachedData };
}

async function createZKValidationData(
  parameters: GetPaymasterDataParameters,
  _currentIdentity: Identity,
  localPool: Group,
  paymaster: CacheEnabledGasLimitedPaymasterContract,
  publicClient: PublicClient,
  proofGenerationTimes: number[]
): Promise<ValidationDataResult> {
  console.log(`   🔬 Using ZK PROOF validation path - generating proof...`);

  const context = parameters.context as Hex;
  const identityStr = hexToString(context);
  const identityObj = Identity.import(identityStr);

  const userOp: UserOperation<'0.7'> = {
    ...parameters,
    callData: parameters.callData,
    callGasLimit: parameters.callGasLimit || 0n,
    maxFeePerGas: parameters.maxFeePerGas || 0n,
    maxPriorityFeePerGas: parameters.maxPriorityFeePerGas || 0n,
    nonce: parameters.nonce,
    preVerificationGas: parameters.preVerificationGas || 0n,
    sender: parameters.sender,
    signature: '0x',
    verificationGasLimit: parameters.verificationGasLimit || 0n,
  };

  const packedUserOp = getPackedUserOperation(userOp);
  const msgHash = getMessageHash(packedUserOp, BigInt(publicClient.chain!.id), entryPoint07Address);
  const scope = await paymaster.read.SCOPE(); // Read scope from contract
  const currentRootIndex = await paymaster.read.currentRootIndex();

  const proofStartTime = Date.now();
  const proof = await generateProof(identityObj, localPool, BigInt(msgHash), scope);
  const proofEndTime = Date.now();
  const proofGenerationTime = proofEndTime - proofStartTime;

  console.log(`   ⚡ Proof generated in ${proofGenerationTime}ms`);
  proofGenerationTimes.push(proofGenerationTime);

  const paymasterData = await generatePaymasterData(currentRootIndex, {
    merkleTreeDepth: BigInt(proof.merkleTreeDepth),
    merkleTreeRoot: BigInt(proof.merkleTreeRoot),
    nullifier: BigInt(proof.nullifier),
    message: BigInt(proof.message),
    scope: BigInt(proof.scope),
    points: proof.points as [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint],
  });

  return { paymasterData };
}

function createSmartAccountClientWithPaymaster(
  publicClient: PublicClient,
  smartAccount: SmartAccount,
  paymaster: CacheEnabledGasLimitedPaymasterContract,
  paymasterContext: string,
  willUseCache: boolean,
  currentIdentity: Identity,
  localPool: Group,
  proofGenerationTimes: number[]
) {
  return createSmartAccountClient({
    client: publicClient,
    account: smartAccount,
    bundlerTransport: http(CONFIG.BUNDLER_URL),
    paymaster: {
      async getPaymasterStubData(_parameters: GetPaymasterStubDataParameters) {
        const stubData = willUseCache
          ? await createCachedStubData()
          : await createZKStubData(paymaster, publicClient);

        return {
          paymaster: paymaster.address,
          ...stubData,
        };
      },
      async getPaymasterData(parameters: GetPaymasterDataParameters) {
        const validationData = willUseCache
          ? await createCachedValidationData()
          : await createZKValidationData(
              parameters,
              currentIdentity,
              localPool,
              paymaster,
              publicClient,
              proofGenerationTimes
            );

        return {
          paymaster: paymaster.address,
          ...validationData,
        };
      },
    },
    paymasterContext,
  });
}

// ============ CACHE ANALYSIS FUNCTIONS ============
async function checkCacheAvailability(
  paymaster: CacheEnabledGasLimitedPaymasterContract,
  smartAccountAddress: `0x${string}`,
  gasConsumption: GasConsumptionData[]
): Promise<CacheAvailabilityResult> {
  const userNullifiersState = await paymaster.read.userNullifiersStates([smartAccountAddress]);
  const decodedState = decodeNullifierState(userNullifiersState);
  const isAlreadyCached = decodedState.activatedNullifierCount > 0;

  if (!isAlreadyCached) {
    return { willUseCache: false, totalAvailable: 0n, gasThreshold: 0n };
  }

  // Calculate total available gas from all slots
  let totalAvailable = 0n;
  for (let j = 0; j < 2; j++) {
    const nullifierKey = keccak256(
      encodeAbiParameters(parseAbiParameters('address, uint8'), [smartAccountAddress, j])
    );
    const nullifier = await paymaster.read.userNullifiers([nullifierKey]);
    if (nullifier > 0n) {
      const used = await paymaster.read.nullifierGasUsage([nullifier]);
      const available = CONFIG.JOINING_AMOUNT > used ? CONFIG.JOINING_AMOUNT - used : 0n;
      totalAvailable += available;
    }
  }

  const gasThreshold = calculateCachedGasThreshold(gasConsumption);
  const willUseCache = totalAvailable > gasThreshold;

  return { willUseCache, totalAvailable, gasThreshold };
}

// ============ TRANSACTION EXECUTION ============
async function executeTransaction(
  testState: TestState,
  paymaster: CacheEnabledGasLimitedPaymasterContract,
  smartAccount: SmartAccount,
  publicClient: PublicClient,
  bundlerClient: BundlerClient,
  transactionNumber: number
): Promise<boolean> {
  try {
    console.log(`\n🔄 Transaction ${transactionNumber} (Phase: ${testState.currentPhase})...`);

    // Analyze cache availability
    const { willUseCache, totalAvailable, gasThreshold } = await checkCacheAvailability(
      paymaster,
      smartAccount.address,
      testState.gasConsumption
    );

    // Update phase and handle identity management
    if (willUseCache) {
      testState.currentPhase = 'CACHED';
      const cachedTxCount = testState.gasConsumption.filter((tx) => tx.isCached).length;
      console.log(`   Using CACHED context - available: ${formatEther(totalAvailable)} ETH`);
      if (cachedTxCount > 0) {
        console.log(
          `   Threshold: ${formatEther(gasThreshold)} ETH (avg of ${cachedTxCount} cached tx${cachedTxCount === 1 ? '' : 's'})`
        );
      } else {
        console.log(`   Threshold: ${formatEther(gasThreshold)} ETH (based on last ZK proof cost)`);
      }
    } else {
      const decodedState = decodeNullifierState(
        await paymaster.read.userNullifiersStates([smartAccount.address])
      );
      const isAlreadyCached = decodedState.activatedNullifierCount > 0;

      if (isAlreadyCached) {
        console.log(
          `   Insufficient cached gas: ${formatEther(totalAvailable)} ETH < ${formatEther(gasThreshold)} ETH`
        );
        testState.currentPhase = 'EXHAUSTED';
        testState.currentIdentity = await addNewIdentity(
          paymaster,
          await hre.viem.getWalletClients().then((w) => w[0]),
          testState.identities.length + 1,
          testState.localPool
        );
        testState.identities.push(testState.currentIdentity);
        console.log(`   New identity added - will activate via ZK proof`);
      } else {
        testState.currentPhase = 'ACTIVATION';
      }
    }

    // Prepare paymaster context
    const paymasterContext = willUseCache ? '0x' : toHex(testState.currentIdentity.export());
    if (!willUseCache) {
      console.log(`   Using ZK PROOF context`);
      testState.currentPhase = 'ACTIVATION';
    }

    // Create smart account client with paymaster
    const smartAccountClient = createSmartAccountClientWithPaymaster(
      publicClient,
      smartAccount,
      paymaster,
      paymasterContext,
      willUseCache,
      testState.currentIdentity,
      testState.localPool,
      testState.proofGenerationTimes
    );

    // Prepare and execute transaction
    const request = await smartAccountClient.prepareUserOperation({
      calls: [{ to: CONFIG.DUMMY_TARGET, data: CONFIG.DUMMY_DATA, value: 0n }],
      paymasterContext,
    });

    const beforeTransactionTotalDeposit = await paymaster.read.totalDeposit();
    const beforeTransactionPaymasterBalance = await paymaster.read.getDeposit();

    const signature = await smartAccount.signUserOperation(request);
    const userOpHash = await bundlerClient.sendUserOperation({
      entryPointAddress: entryPoint07Address,
      ...request,
      signature,
    });

    const receipt = await bundlerClient.waitForUserOperationReceipt({ hash: userOpHash });

    if (receipt.success) {
      console.log(`✅ Transaction ${transactionNumber} successful - Hash: ${userOpHash}`);
      testState.successfulTransactions.push(transactionNumber);
      testState.consecutiveFailures = 0;

      // Record gas consumption data
      testState.gasConsumption.push({
        transaction: transactionNumber,
        gasUsed: Number(receipt.actualGasUsed),
        actualGasCost: Number(receipt.actualGasCost),
        isZKProof: !willUseCache,
        isCached: willUseCache,
        phase: testState.currentPhase,
      });

      // Display transaction metrics
      await displayTransactionMetrics(
        paymaster,
        receipt,
        beforeTransactionTotalDeposit,
        beforeTransactionPaymasterBalance,
        willUseCache
      );

      // Display state and pool info
      await displayNullifierState(paymaster, smartAccount.address, transactionNumber);
      await displayPoolInfo(paymaster);

      return true;
    } else {
      console.log(`❌ Transaction ${transactionNumber} failed - Hash: ${userOpHash}`);
      testState.failedTransactions.push(transactionNumber);
      testState.consecutiveFailures++;
      return false;
    }
  } catch (error) {
    console.log(`❌ Transaction ${transactionNumber} failed with error:`, error);
    testState.failedTransactions.push(transactionNumber);
    testState.consecutiveFailures++;
    return false;
  }
}

// ============ DISPLAY FUNCTIONS ============
async function displayTransactionMetrics(
  paymaster: CacheEnabledGasLimitedPaymasterContract,
  receipt: TransactionReceipt,
  beforeTotalDeposit: bigint,
  beforePaymasterBalance: bigint,
  willUseCache: boolean
): Promise<void> {
  const afterTransactionTotalDeposit = await paymaster.read.totalDeposit();
  const afterTransactionPaymasterBalance = await paymaster.read.getDeposit();
  const amountUserPaid = beforeTotalDeposit - afterTransactionTotalDeposit;
  const amountPaymasterPaid = beforePaymasterBalance - afterTransactionPaymasterBalance;
  const revenueEarnedFromTransaction = amountUserPaid - amountPaymasterPaid;

  console.log(`💰 Amount Users Pay for tx: ${formatEther(amountUserPaid)} ETH`);
  console.log(`💰 Amount Paymaster Paid for tx: ${formatEther(amountPaymasterPaid)} units`);
  console.log(`💰 Revenue Earned from tx: ${formatEther(revenueEarnedFromTransaction)} ETH`);
  console.log(
    `💰 Revenue/PaymasterPaid Percentage : ${(revenueEarnedFromTransaction * BigInt(10000)) / amountPaymasterPaid} %`
  );
  console.log(
    `💰 Revenue/UserPaid Percentage : ${(revenueEarnedFromTransaction * BigInt(10000)) / amountUserPaid} %`
  );
  console.log(`💰 Gas used: ${receipt.actualGasUsed.toLocaleString()} units`);
  console.log(`💰 Actual cost: ${formatEther(receipt.actualGasCost)} ETH`);
  console.log(`📊 Validation type: ${willUseCache ? 'CACHED' : 'ZK PROOF'}`);
}

async function displayPoolInfo(paymaster: CacheEnabledGasLimitedPaymasterContract): Promise<void> {
  const poolSize = await paymaster.read.currentTreeSize();
  const totalDeposits = await paymaster.read.totalDeposit();
  console.log(`   Pool size: ${poolSize}, Total deposits: ${formatEther(totalDeposits)} ETH`);
}

// ============ FINAL ANALYSIS FUNCTIONS ============
function displayFinalSummary(testState: TestState, totalTransactions: number): void {
  console.log('\n📊 FINAL SUMMARY:');
  console.log(`👥 Total identities created: ${testState.identities.length}`);
  console.log(`🔄 Total transactions executed: ${totalTransactions}`);
  console.log(`✅ Successful transactions: ${testState.successfulTransactions.length}`);
  console.log(`❌ Failed transactions: ${testState.failedTransactions.length}`);

  if (testState.successfulTransactions.length > 0) {
    console.log(`Successful transactions: ${testState.successfulTransactions.join(', ')}`);
  }
  if (testState.failedTransactions.length > 0) {
    console.log(`Failed transactions: ${testState.failedTransactions.join(', ')}`);
  }
}

function displayPhaseAnalysis(gasConsumption: GasConsumptionData[]): void {
  console.log('\n🔄 TRANSACTION PHASES:');
  let currentPhase = '';
  gasConsumption.forEach((tx) => {
    if (tx.phase !== currentPhase) {
      currentPhase = tx.phase;
      console.log(`\n📍 ${tx.phase} Phase:`);
    }
    console.log(
      `  Transaction ${tx.transaction}: ${tx.gasUsed.toLocaleString()} gas, ${formatEther(BigInt(tx.actualGasCost))} ETH`
    );
  });
}

function displayGasAnalysis(gasConsumption: GasConsumptionData[]): void {
  console.log('\n⛽ GAS CONSUMPTION ANALYSIS:');
  const zkProofTransactions = gasConsumption.filter((tx) => tx.isZKProof);
  const cachedTransactions = gasConsumption.filter((tx) => tx.isCached);

  if (zkProofTransactions.length > 0) {
    const avgZKCost =
      zkProofTransactions.reduce((sum, tx) => sum + tx.actualGasCost, 0) /
      zkProofTransactions.length;
    console.log(
      `ZK Proof transactions (${zkProofTransactions.length}): Average cost: ${formatEther(BigInt(Math.round(avgZKCost)))} ETH`
    );
  }

  if (cachedTransactions.length > 0) {
    const avgCachedCost =
      cachedTransactions.reduce((sum, tx) => sum + tx.actualGasCost, 0) / cachedTransactions.length;
    console.log(
      `Cached transactions (${cachedTransactions.length}): Average cost: ${formatEther(BigInt(Math.round(avgCachedCost)))} ETH`
    );

    if (zkProofTransactions.length > 0) {
      const avgZKCost =
        zkProofTransactions.reduce((sum, tx) => sum + tx.actualGasCost, 0) /
        zkProofTransactions.length;
      const costSavings = avgZKCost - avgCachedCost;
      console.log(
        `💰 SAVINGS with caching: ${formatEther(BigInt(Math.round(costSavings)))} ETH per tx (${((costSavings / avgZKCost) * 100).toFixed(1)}%)`
      );
    }
  }
}

function displayPerformanceAnalysis(proofGenerationTimes: number[]): void {
  if (proofGenerationTimes.length > 0) {
    const avgProofTime =
      proofGenerationTimes.reduce((a, b) => a + b, 0) / proofGenerationTimes.length;
    const minProofTime = Math.min(...proofGenerationTimes);
    const maxProofTime = Math.max(...proofGenerationTimes);

    console.log('\n⚡ PROOF GENERATION PERFORMANCE:');
    console.log(`Average time: ${avgProofTime.toFixed(2)}ms`);
    console.log(`Fastest: ${minProofTime}ms, Slowest: ${maxProofTime}ms`);
    console.log(`Total ZK proof transactions: ${proofGenerationTimes.length}`);
  }
}

async function displayFinalContractState(
  paymaster: CacheEnabledGasLimitedPaymasterContract,
  smartAccountAddress: `0x${string}`,
  totalTransactions: number
): Promise<void> {
  const finalPoolSize = await paymaster.read.currentTreeSize();
  const finalPoolDeposits = await paymaster.read.totalDeposit();

  console.log(`\n📈 FINAL CONTRACT STATE:`);
  console.log(`Pool size: ${finalPoolSize} members`);
  console.log(`Pool deposits: ${formatEther(finalPoolDeposits)} ETH`);

  await displayNullifierState(paymaster, smartAccountAddress, totalTransactions);
}

// ============ ANALYSIS UTILITY FUNCTIONS ============

function shouldTerminateEarly(
  gasConsumption: GasConsumptionData[],
  identityCount: number
): boolean {
  if (gasConsumption.length >= 10 && identityCount >= 3) {
    const phases = gasConsumption.map((tx) => tx.phase);
    const uniquePhases = [...new Set(phases)];

    if (
      uniquePhases.includes('ACTIVATION') &&
      uniquePhases.includes('CACHED') &&
      uniquePhases.includes('EXHAUSTED')
    ) {
      console.log(`\n🎯 Successfully demonstrated complete nullifier lifecycle!`);
      console.log(`   Phases demonstrated: ${uniquePhases.join(', ')}`);
      console.log(`   Identities created: ${identityCount}`);
      return true;
    }
  }
  return false;
}

// ============ MAIN EXECUTION FUNCTION ============
async function main() {
  const [wallet1] = await hre.viem.getWalletClients();
  const publicClient = await hre.viem.getPublicClient();

  // Deploy and initialize
  const paymaster = await deployPaymaster();
  const localPool = await initializePool(paymaster, wallet1);

  // Setup smart account and bundler
  const smartAccount = await toSimpleSmartAccount({
    owner: wallet1,
    client: publicClient,
    entryPoint: { address: entryPoint07Address, version: '0.7' },
  });

  const bundlerClient = createBundlerClient({
    client: publicClient,
    transport: http(CONFIG.BUNDLER_URL),
  });

  // Initialize test state
  const testState: TestState = {
    identities: [],
    successfulTransactions: [],
    failedTransactions: [],
    proofGenerationTimes: [],
    gasConsumption: [],
    localPool,
    currentIdentity: await addNewIdentity(paymaster, wallet1, 1, localPool),
    currentPhase: 'ACTIVATION',
    consecutiveFailures: 0,
  };

  testState.identities.push(testState.currentIdentity);

  // Execute transaction loop
  let transactionNumber = 1;
  while (transactionNumber <= CONFIG.MAX_TOTAL_TRANSACTIONS) {
    const success = await executeTransaction(
      testState,
      paymaster,
      smartAccount,
      publicClient,
      bundlerClient,
      transactionNumber
    );

    if (!success) {
      if (testState.consecutiveFailures >= CONFIG.MAX_CONSECUTIVE_FAILURES) {
        console.log(`🛑 Stopping after ${CONFIG.MAX_CONSECUTIVE_FAILURES} consecutive failures`);
        break;
      }

      if (testState.currentPhase === 'CACHED') {
        console.log(`   Cache exhausted - will add new identity and retry`);
        testState.currentPhase = 'EXHAUSTED';
        continue;
      } else {
        console.log(`   Fatal error in ${testState.currentPhase} phase`);
        break;
      }
    }

    // Check for early termination
    if (shouldTerminateEarly(testState.gasConsumption, testState.identities.length)) {
      break;
    }

    transactionNumber++;
  }

  // Final analysis and reporting
  const totalTransactions = transactionNumber - 1;
  displayFinalSummary(testState, totalTransactions);
  displayPhaseAnalysis(testState.gasConsumption);
  displayGasAnalysis(testState.gasConsumption);
  displayPerformanceAnalysis(testState.proofGenerationTimes);
  await displayFinalContractState(paymaster, smartAccount.address, totalTransactions);
}

main().catch((err) => {
  console.error('💥 Script failed:', err);
  process.exit(1);
});
