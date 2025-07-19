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

// Helper function to calculate user state key locally
function getUserStateKey(poolId: bigint, sender: `0x${string}`): `0x${string}` {
  return keccak256(encodeAbiParameters(parseAbiParameters('uint256, address'), [poolId, sender]));
}

// Helper function to decode nullifier state flags
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
  // Filter to get only cached transactions with actual costs
  const cachedTransactions = gasConsumption.filter((tx) => tx.isCached && tx.actualGasCost);

  if (cachedTransactions.length === 0) {
    // No cached transactions yet - use the most recent ZK proof cost as safe upper bound
    const zkProofTransactions = gasConsumption.filter((tx) => tx.isZKProof && tx.actualGasCost);
    if (zkProofTransactions.length > 0) {
      const lastZKCost = zkProofTransactions[zkProofTransactions.length - 1].actualGasCost;
      return BigInt(lastZKCost); // ZK proof cost is definitely safe for cached tx
    }
    // Fallback only if no transactions at all
    return parseEther('0.003');
  }

  // Calculate average actual cost of cached transactions
  const avgCachedCost =
    cachedTransactions.reduce((sum, tx) => sum + tx.actualGasCost, 0) / cachedTransactions.length;

  // Add 20% buffer for safety (cached transactions should be very consistent)
  return (BigInt(Math.round(avgCachedCost)) * 200n) / 100n;
}

async function main() {
  const [wallet1] = await hre.viem.getWalletClients();
  const publicClient = await hre.viem.getPublicClient();

  // Deploy SimpleCacheEnabledGasLimitedPaymaster
  const paymaster = await hre.viem.deployContract(
    'SimpleCacheEnabledGasLimitedPaymaster',
    [entryPoint07Address, '0x6C42599435B82121794D835263C846384869502d'],
    {
      libraries: { PoseidonT3: '0xB43122Ecb241DD50062641f089876679fd06599a' },
    }
  );

  console.log(`🚀 SimpleCacheEnabledGasLimitedPaymaster deployed at: ${paymaster.address}`);

  const joiningFee = parseEther('0.005'); // Smaller fee for more transactions
  await paymaster.write.createPool([joiningFee]);
  await paymaster.write.createPool([parseEther('1')]);
  const poolId = 1n;

  // Initial setup with dummy identity
  const dummyId = new Identity(await wallet1.signMessage({ message: 'dummy' }));
  const dummyId2 = new Identity(await wallet1.signMessage({ message: 'dummy2' }));
  let localPool = new Group([dummyId.commitment, dummyId2.commitment]);
  await paymaster.write.addMember([poolId, dummyId.commitment], { value: joiningFee });
  await paymaster.write.addMember([poolId, dummyId2.commitment], { value: joiningFee });
  await paymaster.write.addMember([2n, dummyId2.commitment], { value: parseEther('1') });

  const smartAccount = await toSimpleSmartAccount({
    owner: wallet1,
    client: publicClient,
    entryPoint: { address: entryPoint07Address, version: '0.7' },
  });

  const bundlerClient = createBundlerClient({
    client: publicClient,
    transport: http('http://localhost:4337'),
  });

  // Track test data
  const identities: Identity[] = [];
  const successfulTransactions: number[] = [];
  const failedTransactions: number[] = [];
  const proofGenerationTimes: number[] = [];
  const gasConsumption: GasConsumptionData[] = [];

  // Helper function to display current nullifier state
  async function displayNullifierState(transactionNum: number): Promise<void> {
    const userStateKey = getUserStateKey(poolId, smartAccount.address);
    const userNullifiersStateFlags = await paymaster.read.userNullifiersStates([userStateKey]);
    const decodedState = decodeNullifierState(userNullifiersStateFlags);

    console.log(`\n📊 Nullifier State After Transaction ${transactionNum}:`);
    console.log(`   Active count: ${decodedState.activatedNullifierCount}`);
    console.log(`   Has exhausted slot: ${decodedState.hasAvailableExhaustedSlot}`);
    console.log(`   Exhausted slot index: ${decodedState.exhaustedSlotIndex}`);

    for (let j = 0; j < 2; j++) {
      const nullifier = await paymaster.read.userNullifiers([userStateKey, BigInt(j)]);
      if (nullifier > 0n) {
        const used = await paymaster.read.nullifierGasUsage([nullifier]);
        const available = joiningFee > used ? joiningFee - used : 0n;
        console.log(
          `   Slot ${j}: ${nullifier.toString().slice(0, 12)}..., used: ${formatEther(used)} ETH, available: ${formatEther(available)} ETH`
        );
      } else {
        console.log(`   Slot ${j}: EMPTY`);
      }
    }
  }

  // Start with adding first identity
  console.log(`\n🆔 Adding first identity to pool...`);
  let currentIdentity = new Identity(await wallet1.signMessage({ message: `identity-1` }));
  identities.push(currentIdentity);
  await paymaster.write.addMember([poolId, currentIdentity.commitment], { value: joiningFee });
  await new Promise((resolve) => setTimeout(resolve, 2000));
  localPool.addMember(currentIdentity.commitment);
  console.log(`   Identity added to pool`);

  let i = 1;
  let currentPhase = 'ACTIVATION'; // ACTIVATION, CACHED, or EXHAUSTED
  let consecutiveFailures = 0;
  const MAX_CONSECUTIVE_FAILURES = 3;
  const MAX_TOTAL_TRANSACTIONS = 78; // Safety limit

  while (i <= MAX_TOTAL_TRANSACTIONS) {
    try {
      console.log(`\n🔄 Transaction ${i} (Phase: ${currentPhase})...`);

      // Check current state
      const userStateKey = getUserStateKey(poolId, smartAccount.address);
      const userNullifiersStateFlags = await paymaster.read.userNullifiersStates([userStateKey]);
      const decodedState = decodeNullifierState(userNullifiersStateFlags);
      const isAlreadyCached = decodedState.activatedNullifierCount > 0;

      // Determine paymaster context - ALWAYS initialize first
      let paymasterContext = '0x';
      let willUseCache = false;

      // Clean logic: check cache availability and decide accordingly
      if (isAlreadyCached) {
        // Check if we have available gas for cached operation
        let totalAvailable = 0n;

        for (let j = 0; j < 2; j++) {
          const nullifier = await paymaster.read.userNullifiers([userStateKey, BigInt(j)]);
          if (nullifier > 0n) {
            const used = await paymaster.read.nullifierGasUsage([nullifier]);
            const available = joiningFee > used ? joiningFee - used : 0n;
            totalAvailable += available;
          }
        }

        // Use cached transaction gas estimation based on actual costs
        const gasThreshold = calculateCachedGasThreshold(gasConsumption);
        const hasEnoughGas = totalAvailable > gasThreshold;

        if (hasEnoughGas) {
          // Use cached validation
          paymasterContext = encodeAbiParameters(parseAbiParameters('uint256'), [poolId]);
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
          // Cache exhausted - need new identity
          console.log(
            `   Insufficient cached gas: ${formatEther(totalAvailable)} ETH < ${formatEther(gasThreshold)} ETH`
          );
          currentPhase = 'EXHAUSTED';
          willUseCache = false;
        }
      } else {
        // No cached nullifiers - use ZK proof
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
          await paymaster.write.addMember([poolId, currentIdentity.commitment], {
            value: joiningFee,
          });
          await new Promise((resolve) => setTimeout(resolve, 2000));
          localPool.addMember(currentIdentity.commitment);
          console.log(`   New identity added - will activate via ZK proof`);
        }

        paymasterContext = encodeAbiParameters(parseAbiParameters('uint256, bytes'), [
          poolId,
          toHex(currentIdentity.export()),
        ]);
        console.log(`   Using ZK PROOF context`);
        currentPhase = 'ACTIVATION';
      }

      // Create smart account client
      const smartAccountClient = createSmartAccountClient({
        client: publicClient,
        account: smartAccount,
        bundlerTransport: http('http://localhost:4337'),
        paymaster: {
          async getPaymasterStubData(parameters: GetPaymasterStubDataParameters) {
            // Generate stub data ourselves to ensure consistency with context

            if (willUseCache) {
              // Generate cached stub data: poolId + mode
              const cachedStubData = encodePacked(
                ['uint256', 'uint8'],
                [poolId, 1] // mode 1 = ESTIMATION
              );

              console.log(`   Stub data: ${cachedStubData.length} bytes (CACHED - self-generated)`);

              return {
                paymaster: paymaster.address,
                paymasterData: cachedStubData,
                paymasterPostOpGasLimit: 55000n,
              };
            } else {
              // Generate ZK proof stub data with dummy values
              const config = BigInt(0) | (BigInt(1) << 32n); // rootIndex=0, mode=1 (ESTIMATION)
              const configBytes = numberToHex(config, { size: 32 });
              const poolIdBytes = encodeAbiParameters([{ type: 'uint256' }], [poolId]);

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
                    merkleTreeRoot: 0n,
                    nullifier: 0n,
                    message: 0n,
                    scope: poolId,
                    points: [0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n],
                  },
                ]
              );

              const zkStubData = concat([configBytes, poolIdBytes, dummyProofBytes]);

              console.log(`   Stub data: ${zkStubData.length} bytes (ZK PROOF - self-generated)`);

              return {
                paymaster: paymaster.address,
                paymasterData: zkStubData,
                paymasterPostOpGasLimit: 86700n,
              };
            }
          },
          async getPaymasterData(parameters: GetPaymasterDataParameters) {
            const context = parameters.context as Hex;

            if (context.length === 66) {
              // Cached path
              console.log(`   🚀 Using CACHED validation path`);
              const decodedPoolId = decodeAbiParameters(parseAbiParameters('uint256'), context)[0];
              const cachedData = encodePacked(['uint256', 'uint8'], [decodedPoolId, 0]);
              return { paymaster: paymaster.address, paymasterData: cachedData };
            } else {
              // ZK proof path
              console.log(`   🔬 Using ZK PROOF validation path - generating proof...`);
              const [decodedPoolId, identityBytes] = decodeAbiParameters(
                parseAbiParameters('uint256, bytes'),
                context
              );

              const identityStr = hexToString(identityBytes);
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

              const packed = getPackedUserOperation(userOp);
              const msgHash = await paymaster.read.getMessageHash([packed]);
              const latestRootInfo = await paymaster.read.getLatestValidRootInfo([decodedPoolId]);

              const proofStartTime = Date.now();
              const proof = await generateProof(
                identityObj,
                localPool,
                BigInt(msgHash),
                decodedPoolId
              );
              const proofEndTime = Date.now();
              const proofGenerationTime = proofEndTime - proofStartTime;

              console.log(`   ⚡ Proof generated in ${proofGenerationTime}ms`);
              proofGenerationTimes.push(proofGenerationTime);

              const paymasterData = await generatePaymasterData(decodedPoolId, latestRootInfo[1], {
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
      // console.log({
      //   verificationGasLimit: request.verificationGasLimit,
      //   preVerificationGas: request.preVerificationGas,
      //   paymasterVerificationGasLimit: request.paymasterVerificationGasLimit,
      //   paymasterPostOpGasLimit: request.paymasterPostOpGasLimit,
      //   callGasLimit: request.callGasLimit,
      // });
      const beforeTransactionTotalUsersDeposit = await paymaster.read.totalUsersDeposit();
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
        consecutiveFailures = 0; // Reset on success

        const gasUsed = receipt.actualGasUsed;
        const actualGasCost = receipt.actualGasCost; // This is the real ETH cost!

        gasConsumption.push({
          transaction: i,
          gasUsed: Number(gasUsed),
          actualGasCost: Number(actualGasCost), // Store actual ETH cost from receipt
          isZKProof: !willUseCache,
          isCached: willUseCache,
          phase: currentPhase,
        });
        const afterTransactionTotalUsersDeposit = await paymaster.read.totalUsersDeposit();
        const afterTransactionPaymasterBalance = await paymaster.read.getDeposit();
        const amountUserPaid =
          beforeTransactionTotalUsersDeposit - afterTransactionTotalUsersDeposit;
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

        console.log(`   💰 Gas used: ${gasUsed.toLocaleString()} units`);
        console.log(`   💰 Actual cost: ${formatEther(actualGasCost)} ETH`);
        console.log(`   📊 Validation type: ${willUseCache ? 'CACHED' : 'ZK PROOF'}`);

        // Display nullifier state after transaction
        await displayNullifierState(i);

        // Check pool status
        const poolDeposits = await paymaster.read.getPoolDeposits([poolId]);
        const poolSize = await paymaster.read.getMerkleTreeSize([poolId]);
        console.log(`   Pool size: ${poolSize}, Total deposits: ${formatEther(poolDeposits)} ETH`);

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

  // Final analysis
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
  const finalPoolSize = await paymaster.read.getMerkleTreeSize([poolId]);
  const finalPoolDeposits = await paymaster.read.getPoolDeposits([poolId]);
  const revenue = await paymaster.read.getRevenue();

  console.log(`\n📈 FINAL CONTRACT STATE:`);
  console.log(`Pool size: ${finalPoolSize} members`);
  console.log(`Pool deposits: ${formatEther(finalPoolDeposits)} ETH`);
  console.log(`💰 Paymaster revenue: ${formatEther(revenue)} ETH`);

  await displayNullifierState(totalTransactions);
}

async function generatePaymasterData(
  poolId: bigint,
  merkleRootIndex: number,
  proof: {
    merkleTreeDepth: bigint;
    merkleTreeRoot: bigint;
    nullifier: bigint;
    message: bigint;
    scope: bigint;
    points: [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint];
  }
): Promise<Hex> {
  const config = BigInt(merkleRootIndex) | (BigInt(0) << 32n);
  const configBytes = numberToHex(config, { size: 32 });
  const poolIdBytes = encodeAbiParameters([{ type: 'uint256' }], [poolId]);
  const proofBytes = encodeAbiParameters(
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
    [proof]
  );
  return concat([configBytes, poolIdBytes, proofBytes]);
}

main().catch((err) => {
  console.error('💥 Script failed:', err);
  process.exit(1);
});
