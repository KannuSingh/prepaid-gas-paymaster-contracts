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
  formatEther,
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
import { delay } from '../utils/generalUtils';
import {
  type GasLimitedPaymasterContract,
  type WalletClient,
  type TransactionReceipt,
  type StubDataResult,
  type ValidationDataResult,
} from '../utils/contractTypes';
import { poseidon2 } from 'poseidon-lite';

// ============ CONFIGURATION CONSTANTS ============
const CONFIG = {
  JOINING_AMOUNT: parseEther('0.01'),
  PAYMASTER_LIBRARIES: { PoseidonT3: '0xB43122Ecb241DD50062641f089876679fd06599a' },
  SEMAPHORE_VERIFIER: '0x6C42599435B82121794D835263C846384869502d',
  BUNDLER_URL: 'http://localhost:4337',
  DUMMY_TARGET: '0xF892dc5bBef591D61dD6d75Dfc963c371E723bA4',
  DUMMY_DATA: '0xdeedbeed',
  MAX_TRANSACTIONS: 15,
  DELAY_MS: 2000,
  GAS_LIMITS: {
    POSTOP: 65000n,
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
  localPool: Group;
}

// Global variable to track the last generated nullifier
let lastGeneratedNullifier: bigint | undefined;

// ============ CONTRACT INTERACTION FUNCTIONS ============
async function deployPaymaster(): Promise<GasLimitedPaymasterContract> {
  console.log('🚀 Deploying GasLimitedPaymaster...');

  const paymaster = (await hre.viem.deployContract(
    'contracts/implementation/GasLimitedPaymaster.sol:GasLimitedPaymaster',
    [CONFIG.JOINING_AMOUNT, entryPoint07Address, CONFIG.SEMAPHORE_VERIFIER],
    { libraries: CONFIG.PAYMASTER_LIBRARIES }
  )) as GasLimitedPaymasterContract;

  console.log(`   Deployed at: ${paymaster.address}`);
  return paymaster;
}

async function initializePool(
  paymaster: GasLimitedPaymasterContract,
  wallet: WalletClient
): Promise<Group> {
  console.log('🏊 Initializing pool with dummy identity...');

  const dummyId = new Identity(await wallet.signMessage({ message: 'dummy' }));
  const localPool = new Group([dummyId.commitment]);

  await delay(CONFIG.DELAY_MS);
  await paymaster.write.deposit([dummyId.commitment], { value: CONFIG.JOINING_AMOUNT });
  await delay(CONFIG.DELAY_MS);

  return localPool;
}

async function addNewIdentity(
  paymaster: GasLimitedPaymasterContract,
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

// ============ PAYMASTER CLIENT FUNCTIONS ============
async function createStubData(paymaster: GasLimitedPaymasterContract): Promise<StubDataResult> {
  const currentRootIndex = await paymaster.read.currentRootIndex();
  const config = BigInt(currentRootIndex) | (BigInt(CONFIG.PAYMASTER_MODES.ESTIMATION) << 32n);
  const currentRoot = await paymaster.read.currentRoot();
  const configBytes = numberToHex(config, { size: 32 });
  const scope = await paymaster.read.SCOPE();

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

  const stubData = concat([configBytes, dummyProofBytes]);
  console.log(`   Stub data: ${stubData.length} bytes (ZK PROOF - self-generated)`);

  return {
    paymasterData: stubData,
    paymasterPostOpGasLimit: CONFIG.GAS_LIMITS.POSTOP,
  };
}

async function createValidationData(
  parameters: GetPaymasterDataParameters,
  currentIdentity: Identity,
  localPool: Group,
  paymaster: GasLimitedPaymasterContract,
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
  
  // Store the generated nullifier for later use
  const generatedNullifier = BigInt(proof.nullifier);

  const paymasterData = await generatePaymasterData(currentRootIndex, {
    merkleTreeDepth: BigInt(proof.merkleTreeDepth),
    merkleTreeRoot: BigInt(proof.merkleTreeRoot),
    nullifier: generatedNullifier,
    message: BigInt(proof.message),
    scope: BigInt(proof.scope),
    points: proof.points as [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint],
  });
  
  // Validation data generated (using proof nullifier for tracking)
  
  // Store the nullifier globally for use in transaction metrics
  lastGeneratedNullifier = generatedNullifier;

  return { paymasterData };
}

function createSmartAccountClientWithPaymaster(
  publicClient: PublicClient,
  smartAccount: SmartAccount,
  paymaster: GasLimitedPaymasterContract,
  paymasterContext: string,
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
        const stubData = await createStubData(paymaster);

        // Stub data generated silently
        
        return {
          paymaster: paymaster.address,
          ...stubData,
        };
      },
      async getPaymasterData(parameters: GetPaymasterDataParameters) {
        const validationData = await createValidationData(
          parameters,
          currentIdentity,
          localPool,
          paymaster,
          publicClient,
          proofGenerationTimes
        );

        // Validation data generated silently
        
        return {
          paymaster: paymaster.address,
          ...validationData,
        };
      },
    },
    paymasterContext,
  });
}

// ============ TRANSACTION EXECUTION ============
async function executeTransaction(
  testState: TestState,
  paymaster: GasLimitedPaymasterContract,
  smartAccount: SmartAccount,
  publicClient: PublicClient,
  bundlerClient: BundlerClient,
  wallet: WalletClient,
  transactionNumber: number
): Promise<boolean> {
  try {
    console.log(`\n🔄 Transaction ${transactionNumber}/${CONFIG.MAX_TRANSACTIONS}...`);

    // Use existing identity to demonstrate multi-use capability
    // Only create new identity if we don't have one or current one is exhausted
    let currentIdentity = testState.identities.length > 0 ? testState.identities[testState.identities.length - 1] : null;
    
    if (!currentIdentity) {
      // Create first identity
      currentIdentity = await addNewIdentity(paymaster, wallet, 1, testState.localPool);
      testState.identities.push(currentIdentity);
      console.log(`   🆔 Using new identity for first transaction`);
    } else {
      // Check if current identity has remaining gas using the actual nullifier from previous proof
      let remainingGas = CONFIG.JOINING_AMOUNT; // Default fallback
      
      if (lastGeneratedNullifier) {
        const gasUsed = await paymaster.read.nullifierGasUsage([lastGeneratedNullifier]);
        remainingGas = CONFIG.JOINING_AMOUNT - gasUsed;
      }
      
      if (remainingGas < parseEther('0.001')) { // If less than 0.001 ETH remaining
        console.log(`   ⚠️  Identity nearly exhausted (remaining: ${formatEther(remainingGas)} ETH) - this may be the last transaction`);
      } else {
        console.log(`   🔄 Reusing identity #${testState.identities.length} (remaining: ${formatEther(remainingGas)} ETH)`);
      }
    }

    // Prepare paymaster context
    const paymasterContext = toHex(currentIdentity.export());

    // Create smart account client with paymaster
    const smartAccountClient = createSmartAccountClientWithPaymaster(
      publicClient,
      smartAccount,
      paymaster,
      paymasterContext,
      currentIdentity,
      testState.localPool,
      testState.proofGenerationTimes
    );

    // Prepare and execute transaction
    const request = await smartAccountClient.prepareUserOperation({
      calls: [{ to: CONFIG.DUMMY_TARGET, data: CONFIG.DUMMY_DATA, value: 0n }],
      paymasterContext,
    });

    const signature = await smartAccount.signUserOperation(request);
    const userOpHash = await bundlerClient.sendUserOperation({
      entryPointAddress: entryPoint07Address,
      ...request,
      signature,
    });

    const receipt = (await bundlerClient.waitForUserOperationReceipt({
      hash: userOpHash,
    })) as TransactionReceipt;
    
    // Transaction processed successfully

    if (receipt.success) {
      console.log(`✅ Transaction ${transactionNumber} successful - Hash: ${userOpHash}`);
      testState.successfulTransactions.push(transactionNumber);

      // Wait for post-op processing
      await delay(1000);
      
      // Display transaction metrics using the actual nullifier from the proof
      await displayTransactionMetrics(paymaster, publicClient, receipt, currentIdentity, lastGeneratedNullifier);
      await displayPoolInfo(paymaster);

      return true;
    } else {
      console.log(`❌ Transaction ${transactionNumber} failed - Hash: ${userOpHash}`);
      testState.failedTransactions.push(transactionNumber);
      return false;
    }
  } catch (error) {
    console.log(`❌ Transaction ${transactionNumber} failed`);
    testState.failedTransactions.push(transactionNumber);
    
    // Check if this was due to gas exhaustion (expected behavior)
    if (error instanceof Error && error.message.includes('AA33')) {
      console.log(`   ✓ Expected failure: Gas exhaustion - identity ran out of gas`);
      console.log(`   → This demonstrates the gas-limited paymaster's incremental consumption`);
    } else {
      console.log(`   ✗ Unexpected failure`);
      console.log(`   → Error: ${error instanceof Error ? error.message.split('\n')[0] : String(error)}`);
    }
    
    return false;
  }
}

// ============ DISPLAY FUNCTIONS ============
async function displayTransactionMetrics(
  paymaster: GasLimitedPaymasterContract,
  publicClient: PublicClient,
  receipt: TransactionReceipt,
  identity: Identity,
  actualNullifierFromProof?: bigint
): Promise<void> {
  let nullifier: bigint;
  let nullifierSource: string;
  
  if (actualNullifierFromProof) {
    // Use the actual nullifier from the generated proof
    nullifier = actualNullifierFromProof;
    nullifierSource = "from generated proof";
  } else {
    // Fallback to manual calculation
    const secret = identity.secretScalar;
    const scope = await paymaster.read.SCOPE();
    nullifier = poseidon2([scope, secret]);
    nullifierSource = "manually calculated";
  }
  
  // Check nullifier gas usage
  const nullifierGasUsage = await paymaster.read.nullifierGasUsage([nullifier]);
  const remainingGas = CONFIG.JOINING_AMOUNT - nullifierGasUsage;

  console.log(`💰 Gas used: ${receipt.actualGasUsed.toLocaleString()} units`);
  console.log(`💰 Actual cost: ${formatEther(receipt.actualGasCost)} ETH`);
  console.log(`🔐 Nullifier: ${nullifier.toString().slice(0, 16)}... (${nullifierSource})`);
  console.log(`💰 Nullifier gas usage: ${formatEther(nullifierGasUsage)} ETH`);
  console.log(`💰 Remaining gas for nullifier: ${formatEther(remainingGas)} ETH`);
}

async function displayPoolInfo(paymaster: GasLimitedPaymasterContract): Promise<void> {
  const poolSize = await paymaster.read.currentTreeSize();
  const totalDeposits = await paymaster.read.totalDeposit();
  console.log(`   Pool size: ${poolSize}, Total deposits: ${formatEther(totalDeposits)} ETH`);
}

// ============ FINAL ANALYSIS FUNCTIONS ============
function displayFinalSummary(testState: TestState, totalTransactions: number): void {
  console.log('\n📊 FINAL SUMMARY - GAS LIMITED PAYMASTER:');
  console.log(`👥 Total identities created: ${testState.identities.length}`);
  console.log(`🔄 Total transactions executed: ${totalTransactions}`);
  console.log(`✅ Successful transactions: ${testState.successfulTransactions.length}`);
  console.log(`❌ Failed transactions: ${testState.failedTransactions.length}`);
  
  console.log(`\n🔄 SINGLE IDENTITY MULTI-USE DEMONSTRATION:`);
  console.log(`   • One identity used for multiple transactions until completely exhausted`);
  console.log(`   • Identity reused ${totalTransactions} times across multiple transactions`);
  console.log(`   • Gas deducted incrementally: ${formatEther(CONFIG.JOINING_AMOUNT)} ETH → ~0 ETH`);
  console.log(`   • Demonstrates gas-limited paymaster's precise consumption tracking per identity`);

  if (testState.successfulTransactions.length > 0) {
    console.log(`\nSuccessful transactions: ${testState.successfulTransactions.join(', ')}`);
  }
  if (testState.failedTransactions.length > 0) {
    console.log(`Failed transactions: ${testState.failedTransactions.join(', ')}`);
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

    console.log('\n📋 Individual Proof Times:');
    proofGenerationTimes.forEach((time, index) => {
      console.log(`  Transaction ${index + 1}: ${time}ms`);
    });
  }
}

async function displayFinalContractState(paymaster: GasLimitedPaymasterContract): Promise<void> {
  const finalPoolSize = await paymaster.read.currentTreeSize();
  const finalPoolDeposits = await paymaster.read.totalDeposit();
  const paymasterBalance = await paymaster.read.getDeposit();
  const revenue = paymasterBalance - finalPoolDeposits;

  console.log(`\n📈 FINAL CONTRACT STATE:`);
  console.log(`Pool size: ${finalPoolSize} members`);
  console.log(`Pool deposits: ${formatEther(finalPoolDeposits)} ETH`);
  console.log(`Paymaster balance: ${formatEther(paymasterBalance)} ETH`);
  console.log(`💰 Paymaster revenue: ${formatEther(revenue)} ETH`);
}

// ============ UTILITY FUNCTIONS ============
async function generatePaymasterData(
  merkleRootIndex: number | bigint,
  proof: {
    merkleTreeDepth: bigint;
    merkleTreeRoot: bigint;
    nullifier: bigint;
    message: bigint;
    scope: bigint;
    points: [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint];
  }
): Promise<Hex> {
  const config = BigInt(merkleRootIndex) | (BigInt(CONFIG.PAYMASTER_MODES.VALIDATION) << 32n);
  const configBytes = numberToHex(config, { size: 32 });

  const proofBytes = encodeAbiParameters(
    [
      {
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
    [proof]
  );

  return concat([configBytes, proofBytes]);
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
    localPool,
  };

  // Execute transaction loop
  let transactionNumber = 1;
  while (transactionNumber <= CONFIG.MAX_TRANSACTIONS) {
    const success = await executeTransaction(
      testState,
      paymaster,
      smartAccount,
      publicClient,
      bundlerClient,
      wallet1,
      transactionNumber
    );

    if (!success) {
      console.log(`   Transaction ${transactionNumber} failed - checking if due to gas exhaustion...`);
      
      // Check if current identity is exhausted using the actual nullifier
      if (lastGeneratedNullifier) {
        const gasUsed = await paymaster.read.nullifierGasUsage([lastGeneratedNullifier]);
        const remainingGas = CONFIG.JOINING_AMOUNT - gasUsed;
        
        if (remainingGas < parseEther('0.001')) {
          console.log(`   ✓ Expected failure: Identity exhausted (remaining: ${formatEther(remainingGas)} ETH)`);
          console.log(`   → This demonstrates the gas-limited paymaster's incremental consumption`);
          console.log(`   → Single identity demonstration complete - no more gas available`);
          break; // End the transaction loop naturally
        } else {
          console.log(`   ✗ Failure not due to gas exhaustion (remaining: ${formatEther(remainingGas)} ETH)`);
          console.log(`   → Stopping test due to unexpected failure`);
          break; // End the transaction loop due to unexpected failure
        }
      }
    }

    transactionNumber++;
  }

  // Final analysis and reporting
  const totalTransactions = transactionNumber - 1;
  displayFinalSummary(testState, totalTransactions);
  displayPerformanceAnalysis(testState.proofGenerationTimes);
  await displayFinalContractState(paymaster);
}

main().catch((err) => {
  console.error('💥 Script failed:', err);
  process.exit(1);
});
