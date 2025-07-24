import hre from 'hardhat';
import {
  concat,
  encodeAbiParameters,
  decodeAbiParameters,
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
} from 'viem';
import { Identity, Group, generateProof } from '@semaphore-protocol/core';
import {
  createBundlerClient,
  entryPoint07Address,
  GetPaymasterDataParameters,
  GetPaymasterStubDataParameters,
  UserOperation,
} from 'viem/account-abstraction';
import { toSimpleSmartAccount } from 'permissionless/accounts';
import { getPackedUserOperation } from 'permissionless/utils';
import { createSmartAccountClient } from 'permissionless';

// Helper function to decode nullifier state flags (same as old implementation)
function decodeNullifierState(flags: bigint) {
  return {
    activatedNullifierCount: Number(flags & 0xffn),
    exhaustedSlotIndex: Number((flags >> 8n) & 0xffn),
    hasAvailableExhaustedSlot: ((flags >> 16n) & 1n) !== 0n,
  };
}

// Interface for gas consumption tracking
interface GasConsumptionData {
  transaction: number;
  gasUsed: number;
  actualGasCost: number;
  isZKProof: boolean;
  isCached: boolean;
  phase: string;
}

// Helper function to calculate cached gas threshold using actual costs
function calculateCachedGasThreshold(gasConsumption: GasConsumptionData[]): bigint {
  const cachedTransactions = gasConsumption.filter((tx) => tx.isCached && tx.actualGasCost);

  if (cachedTransactions.length === 0) {
    const zkProofTransactions = gasConsumption.filter((tx) => tx.isZKProof && tx.actualGasCost);
    if (zkProofTransactions.length > 0) {
      const lastZKCost = zkProofTransactions[zkProofTransactions.length - 1].actualGasCost;
      return BigInt(lastZKCost);
    }
    return parseEther('0.003');
  }

  const avgCachedCost =
    cachedTransactions.reduce((sum, tx) => sum + tx.actualGasCost, 0) / cachedTransactions.length;

  return (BigInt(Math.round(avgCachedCost)) * 200n) / 100n;
}

async function main() {
  const [wallet1] = await hre.viem.getWalletClients();
  const publicClient = await hre.viem.getPublicClient();

  const joiningAmount = parseEther('0.001'); // Same as old implementation

  // Deploy CacheEnabledGasLimitedPaymaster (new implementation)
  const paymaster = await hre.viem.deployContract(
    'contracts/implementation/CacheEnabledGasLimitedPaymaster.sol:CacheEnabledGasLimitedPaymaster',
    [joiningAmount, entryPoint07Address, '0x6C42599435B82121794D835263C846384869502d'],
    {
      libraries: { PoseidonT3: '0xB43122Ecb241DD50062641f089876679fd06599a' },
    }
  );

  console.log(`🚀 CacheEnabledGasLimitedPaymaster deployed at: ${paymaster.address}`);

  // Initial setup with dummy identities using deposit() instead of addMember()
  const dummyId = new Identity(await wallet1.signMessage({ message: 'dummy' }));
  const dummyId2 = new Identity(await wallet1.signMessage({ message: 'dummy2' }));
  let localPool = new Group([dummyId.commitment, dummyId2.commitment]);

  // Use deposit() method instead of addMember()
  await new Promise((resolve) => setTimeout(resolve, 3000));
  await paymaster.write.deposit([dummyId.commitment], { value: joiningAmount });
  await new Promise((resolve) => setTimeout(resolve, 3000));
  await paymaster.write.deposit([dummyId2.commitment], { value: joiningAmount });

  const smartAccount = await toSimpleSmartAccount({
    owner: wallet1,
    client: publicClient,
    entryPoint: { address: entryPoint07Address, version: '0.7' },
  });

  const bundlerClient = createBundlerClient({
    client: publicClient,
    transport: http('https://api.pimlico.io/v2/84532/rpc?apikey=pim_SbXH2yCdGAtu1uKZhBSMqY'),
  });

  // Track test data
  const identities: Identity[] = [];
  const successfulTransactions: number[] = [];
  const failedTransactions: number[] = [];
  const proofGenerationTimes: number[] = [];
  const gasConsumption: GasConsumptionData[] = [];

  // Helper function to display current nullifier state (adapted for new implementation)
  async function displayNullifierState(transactionNum: number): Promise<void> {
    console.log('Smart Contract Address:', smartAccount.address);
    const userNullifiersState = await paymaster.read.userNullifiersStates([smartAccount.address]);
    const decodedState = decodeNullifierState(userNullifiersState);

    console.log(`\n📊 Nullifier State After Transaction ${transactionNum}:`);
    console.log(`   Active count: ${decodedState.activatedNullifierCount}`);
    console.log(`   Has exhausted slot: ${decodedState.hasAvailableExhaustedSlot}`);
    console.log(`   Exhausted slot index: ${decodedState.exhaustedSlotIndex}`);

    for (let j = 0; j < 2; j++) {
      const nullifierKey = keccak256(
        encodeAbiParameters(parseAbiParameters('address, uint8'), [smartAccount.address, j])
      );
      const nullifier = await paymaster.read.userNullifiers([nullifierKey]);
      if (nullifier > 0n) {
        const used = await paymaster.read.nullifierGasUsage([nullifier]);
        const available = joiningAmount > used ? joiningAmount - used : 0n;
        console.log(
          `   Slot ${j}: ${nullifier.toString().slice(0, 12)}..., used: ${formatEther(used)} ETH, available: ${formatEther(available)} ETH`
        );
      } else {
        console.log(`   Slot ${j}: EMPTY`);
      }
    }
  }

  // Start with adding first identity using deposit()
  console.log(`\n🆔 Adding first identity to pool...`);
  let currentIdentity = new Identity(await wallet1.signMessage({ message: `identity-1` }));
  identities.push(currentIdentity);
  await new Promise((resolve) => setTimeout(resolve, 2000));
  await paymaster.write.deposit([currentIdentity.commitment], { value: joiningAmount });
  await new Promise((resolve) => setTimeout(resolve, 2000));
  localPool.addMember(currentIdentity.commitment);
  console.log(`   Identity added to pool`);

  let i = 1;
  let currentPhase = 'ACTIVATION';
  let consecutiveFailures = 0;
  const MAX_CONSECUTIVE_FAILURES = 3;
  const MAX_TOTAL_TRANSACTIONS = 3;

  while (i <= MAX_TOTAL_TRANSACTIONS) {
    try {
      console.log(`\n🔄 Transaction ${i} (Phase: ${currentPhase})...`);

      // Check current state (adapted for new implementation)
      const userNullifiersState = await paymaster.read.userNullifiersStates([smartAccount.address]);
      const decodedState = decodeNullifierState(userNullifiersState);
      const isAlreadyCached = decodedState.activatedNullifierCount > 0;

      // Determine paymaster context
      let paymasterContext = '0x';
      let willUseCache = false;

      if (isAlreadyCached) {
        // Check if we have available gas for cached operation
        let totalAvailable = 0n;

        for (let j = 0; j < 2; j++) {
          const nullifierKey = keccak256(
            encodeAbiParameters(parseAbiParameters('address, uint8'), [smartAccount.address, j])
          );
          const nullifier = await paymaster.read.userNullifiers([nullifierKey]);
          if (nullifier > 0n) {
            const used = await paymaster.read.nullifierGasUsage([nullifier]);
            const available = joiningAmount > used ? joiningAmount - used : 0n;
            totalAvailable += available;
          }
        }

        const gasThreshold = calculateCachedGasThreshold(gasConsumption);
        const hasEnoughGas = totalAvailable > gasThreshold;

        if (hasEnoughGas) {
          // Use cached validation - no context needed for new implementation
          willUseCache = true;
          currentPhase = 'CACHED';

          const cachedTxCount = gasConsumption.filter((tx) => tx.isCached).length;
          console.log(`   Using CACHED context - available: ${formatEther(totalAvailable)} ETH`);
          if (cachedTxCount > 0) {
            console.log(
              `   Threshold: ${formatEther(gasThreshold)} ETH (avg of ${cachedTxCount} cached tx${cachedTxCount === 1 ? '' : 's'})`
            );
          } else {
            console.log(
              `   Threshold: ${formatEther(gasThreshold)} ETH (based on last ZK proof cost)`
            );
          }
        } else {
          console.log(
            `   Insufficient cached gas: ${formatEther(totalAvailable)} ETH < ${formatEther(gasThreshold)} ETH`
          );
          currentPhase = 'EXHAUSTED';
          willUseCache = false;
        }
      } else {
        willUseCache = false;
        currentPhase = 'ACTIVATION';
      }

      // Handle new identity addition when cache is exhausted or no cache
      if (!willUseCache) {
        if (currentPhase === 'EXHAUSTED') {
          console.log(`💰 Adding new identity to pool (cache exhausted)...`);
          currentIdentity = new Identity(
            await wallet1.signMessage({ message: `identity-${identities.length + 1}` })
          );
          identities.push(currentIdentity);
          await new Promise((resolve) => setTimeout(resolve, 2000));
          await paymaster.write.deposit([currentIdentity.commitment], { value: joiningAmount });
          await new Promise((resolve) => setTimeout(resolve, 2000));
          localPool.addMember(currentIdentity.commitment);
          console.log(`   New identity added - will activate via ZK proof`);
        }

        paymasterContext = toHex(currentIdentity.export());
        console.log(`   Using ZK PROOF context`);
        currentPhase = 'ACTIVATION';
      }

      // Create smart account client
      const smartAccountClient = createSmartAccountClient({
        client: publicClient,
        account: smartAccount,
        bundlerTransport: http(
          'https://api.pimlico.io/v2/84532/rpc?apikey=pim_SbXH2yCdGAtu1uKZhBSMqY'
        ),
        paymaster: {
          async getPaymasterStubData(parameters: GetPaymasterStubDataParameters) {
            if (willUseCache) {
              // Generate cached stub data following old script pattern
              const cachedStubData = encodePacked(['uint8'], [1]); // mode 1 = ESTIMATION

              console.log(`   Stub data: ${cachedStubData.length} bytes (CACHED - self-generated)`);

              return {
                paymaster: paymaster.address,
                paymasterData: cachedStubData,
                paymasterPostOpGasLimit: 45000n,
              };
            } else {
              // Generate ZK proof stub data following old script pattern
              const currentRootIndex = await paymaster.read.currentRootIndex();
              const config = BigInt(currentRootIndex) | (BigInt(1) << 32n); // rootIndex=0, mode=1 (ESTIMATION)
              const currentRoot = await paymaster.read.currentRoot();
              const configBytes = numberToHex(config, { size: 32 });
              const scope = await paymaster.read.SCOPE();

              // Dummy proof for estimation
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
                paymaster: paymaster.address,
                paymasterData: zkStubData,
                paymasterPostOpGasLimit: 86650n,
              };
            }
          },
          async getPaymasterData(parameters: GetPaymasterDataParameters) {
            const context = parameters.context as Hex;

            if (willUseCache) {
              // Cached path (simple mode byte)
              console.log(`   🚀 Using CACHED validation path`);
              const cachedData = encodePacked(['uint8'], [0]); // mode 0 = VALIDATION
              return { paymaster: paymaster.address, paymasterData: cachedData };
            } else {
              // ZK proof path
              console.log(`   🔬 Using ZK PROOF validation path - generating proof...`);

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
              const msgHash = await paymaster.read.getMessageHash([packedUserOp]);
              const scope = await paymaster.read.SCOPE();
              const currentRoot = await paymaster.read.currentRoot();
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
                points: proof.points as [
                  bigint,
                  bigint,
                  bigint,
                  bigint,
                  bigint,
                  bigint,
                  bigint,
                  bigint,
                ],
              });

              return { paymaster: paymaster.address, paymasterData };
            }
          },
        },
        paymasterContext,
      });

      const request = await smartAccountClient.prepareUserOperation({
        calls: [
          { to: '0xF892dc5bBef591D61dD6d75Dfc963c371E723bA4', data: '0xdeedbeed', value: 0n },
        ],
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
        console.log(`✅ Transaction ${i} successful - Hash: ${userOpHash}`);
        successfulTransactions.push(i);
        consecutiveFailures = 0;

        const gasUsed = receipt.actualGasUsed;
        const actualGasCost = receipt.actualGasCost;

        gasConsumption.push({
          transaction: i,
          gasUsed: Number(gasUsed),
          actualGasCost: Number(actualGasCost),
          isZKProof: !willUseCache,
          isCached: willUseCache,
          phase: currentPhase,
        });

        const afterTransactionTotalDeposit = await paymaster.read.totalDeposit();
        const afterTransactionPaymasterBalance = await paymaster.read.getDeposit();
        const amountUserPaid = beforeTransactionTotalDeposit - afterTransactionTotalDeposit;
        const amountPaymasterPaid =
          beforeTransactionPaymasterBalance - afterTransactionPaymasterBalance;
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
        console.log(`💰 Gas used: ${gasUsed.toLocaleString()} units`);
        console.log(`💰 Actual cost: ${formatEther(actualGasCost)} ETH`);
        console.log(`📊 Validation type: ${willUseCache ? 'CACHED' : 'ZK PROOF'}`);

        // Display nullifier state after transaction
        await displayNullifierState(i);

        // Check pool status
        const poolSize = await paymaster.read.currentTreeSize();
        const totalDeposits = await paymaster.read.totalDeposit();
        console.log(`   Pool size: ${poolSize}, Total deposits: ${formatEther(totalDeposits)} ETH`);

        // Check for early termination conditions
        if (gasConsumption.length >= 10 && identities.length >= 3) {
          const phases = gasConsumption.map((tx) => tx.phase);
          const uniquePhases = [...new Set(phases)];

          if (
            uniquePhases.includes('ACTIVATION') &&
            uniquePhases.includes('CACHED') &&
            uniquePhases.includes('EXHAUSTED')
          ) {
            console.log(`\n🎯 Successfully demonstrated complete nullifier lifecycle!`);
            console.log(`   Phases demonstrated: ${uniquePhases.join(', ')}`);
            console.log(`   Identities created: ${identities.length}`);
            break;
          }
        }

        i++;
      } else {
        consecutiveFailures++;
        console.log(`❌ Transaction ${i} failed - Hash: ${userOpHash}`);
        failedTransactions.push(i);

        if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
          console.log(`🛑 Stopping after ${MAX_CONSECUTIVE_FAILURES} consecutive failures`);
          break;
        }

        if (currentPhase === 'CACHED') {
          console.log(`   Cache exhausted - will add new identity and retry`);
          currentPhase = 'EXHAUSTED';
          continue;
        } else {
          console.log(`   Unexpected failure in ${currentPhase} phase`);
          break;
        }
      }
    } catch (error) {
      consecutiveFailures++;
      console.log(`❌ Transaction ${i} failed with error:`, error);

      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        console.log(`🛑 Stopping after ${MAX_CONSECUTIVE_FAILURES} consecutive failures`);
        break;
      }

      if (currentPhase === 'CACHED') {
        console.log(`   Cached transaction failed - will add new identity and retry`);
        currentPhase = 'EXHAUSTED';
        continue;
      } else {
        console.log(`   Fatal error in ${currentPhase} phase`);
        failedTransactions.push(i);
        break;
      }
    }
  }

  // Final analysis (same as original)
  const totalTransactions = i - 1;
  console.log('\n📊 FINAL SUMMARY:');
  console.log(`👥 Total identities created: ${identities.length}`);
  console.log(`🔄 Total transactions executed: ${totalTransactions}`);
  console.log(`✅ Successful transactions: ${successfulTransactions.length}`);
  console.log(`❌ Failed transactions: ${failedTransactions.length}`);

  if (successfulTransactions.length > 0) {
    console.log(`Successful transactions: ${successfulTransactions.join(', ')}`);
  }

  if (failedTransactions.length > 0) {
    console.log(`Failed transactions: ${failedTransactions.join(', ')}`);
  }

  // Phase analysis
  console.log('\n🔄 TRANSACTION PHASES:');
  let currentPhaseAnalysis = '';
  gasConsumption.forEach((tx) => {
    if (tx.phase !== currentPhaseAnalysis) {
      currentPhaseAnalysis = tx.phase;
      console.log(`\n📍 ${tx.phase} Phase:`);
    }
    console.log(
      `  Transaction ${tx.transaction}: ${tx.gasUsed.toLocaleString()} gas, ${formatEther(BigInt(tx.actualGasCost))} ETH`
    );
  });

  // Gas consumption analysis
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

  // Performance analysis
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

  // Final contract state
  const finalPoolSize = await paymaster.read.currentTreeSize();
  const finalPoolDeposits = await paymaster.read.totalDeposit();

  console.log(`\n📈 FINAL CONTRACT STATE:`);
  console.log(`Pool size: ${finalPoolSize} members`);
  console.log(`Pool deposits: ${formatEther(finalPoolDeposits)} ETH`);

  await displayNullifierState(totalTransactions);
}

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
  const config = BigInt(merkleRootIndex) | (BigInt(0) << 32n); // mode = 0 (VALIDATION)

  // Encode config as raw 32 bytes (not ABI encoded)
  const configBytes = numberToHex(config, { size: 32 });

  // Encode proof as struct (416 bytes)
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

main().catch((err) => {
  console.error('💥 Script failed:', err);
  process.exit(1);
});
