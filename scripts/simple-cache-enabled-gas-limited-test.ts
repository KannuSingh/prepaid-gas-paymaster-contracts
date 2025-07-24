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
  toBytes,
  pad,
  concatHex,
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
import { poseidon2 } from 'poseidon-lite';

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
    activeNullifierIndex: Number((flags >> 17n) & 0xffn), // New field
  };
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
  await new Promise((resolve) => setTimeout(resolve, 2000));
  const joiningFee = parseEther('1');
  // Get the return value first
  const { result: poolId1 } = await paymaster.simulate.createPool([joiningFee]);
  console.log({ poolId1 });
  // Then execute the transaction
  await paymaster.write.createPool([joiningFee]);
  const poolCounter = await paymaster.read.poolCounter();
  console.log({ poolCounter });
  const poolId = poolId1;
  await new Promise((resolve) => setTimeout(resolve, 4000));
  // Initial setup with dummy identity
  const dummyId = new Identity(await wallet1.signMessage({ message: 'dummy' }));
  const dummyId2 = new Identity(await wallet1.signMessage({ message: 'dummy2' }));
  let localPool = new Group([dummyId.commitment, dummyId2.commitment]);
  await paymaster.write.addMember([poolId, dummyId.commitment], { value: joiningFee });
  await new Promise((resolve) => setTimeout(resolve, 4000));
  await paymaster.write.addMember([poolId, dummyId2.commitment], { value: joiningFee });
  await new Promise((resolve) => setTimeout(resolve, 4000));
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
  const identities = [];
  const successfulTransactions = [];
  const failedTransactions = [];
  const proofGenerationTimes: number[] = [];
  const gasConsumption = [];

  // Test with multiple transactions to demonstrate caching behavior
  for (let i = 1; i <= 5; i++) {
    try {
      console.log(`\n🆔 Transaction ${i}/5...`);

      let identity;
      let isNewIdentity = false;

      if (i === 1) {
        // First transaction - create new identity
        identity = new Identity(await wallet1.signMessage({ message: `identity-${i}` }));
        identities.push(identity);
        isNewIdentity = true;

        console.log(`💰 Adding identity ${i} to pool...`);
        await paymaster.write.addMember([poolId, identity.commitment], { value: joiningFee });
        await new Promise((resolve) => setTimeout(resolve, 2000));
        localPool.addMember(identity.commitment);
        console.log(`   New identity added - will require ZK proof`);
      } else if (i <= 3) {
        // Transactions 2-3: Use same identity (should be cached)
        identity = identities[0];
        console.log(`   Reusing identity from transaction 1 - should use cached validation`);
      } else {
        // Transactions 4-5: Create new identity
        identity = new Identity(await wallet1.signMessage({ message: `identity-${i}` }));
        identities.push(identity);
        isNewIdentity = true;

        console.log(`💰 Adding identity ${i} to pool...`);
        await paymaster.write.addMember([poolId, identity.commitment], { value: joiningFee });
        await new Promise((resolve) => setTimeout(resolve, 2000));
        localPool.addMember(identity.commitment);
        console.log(`   New identity added - will require ZK proof`);
      }
      await new Promise((resolve) => setTimeout(resolve, 2000)); // 2 second delay

      // Check cache status before transaction using new userNullifiersStates mapping
      const userStateKey = getUserStateKey(poolId, smartAccount.address);
      const userNullifiersStateFlags = await paymaster.read.userNullifiersStates([userStateKey]);
      const decodedState = decodeNullifierState(userNullifiersStateFlags);
      const isAlreadyCached = decodedState.activatedNullifierCount > 0;

      console.log(
        `   Cache status: ${isAlreadyCached ? 'CACHED' : 'NOT CACHED'} (count: ${decodedState.activatedNullifierCount})`
      );

      // Determine the correct paymaster context based on cache status
      let paymasterContext: Hex;
      if (isAlreadyCached) {
        // For cached senders, only pass poolId (simpler format)
        paymasterContext = encodeAbiParameters(parseAbiParameters('uint256'), [poolId]);
        console.log(`   Using CACHED context (poolId only)`);
      } else {
        // For new senders, pass poolId and identity
        paymasterContext = encodeAbiParameters(parseAbiParameters('uint256, bytes'), [
          poolId,
          toHex(identity.export()),
        ]);
        console.log(`   Using ZK PROOF context (poolId + identity)`);
      }

      console.log(`🚀 Submitting UserOp ${i}/5...`);

      const smartAccountClient = createSmartAccountClient({
        client: publicClient,
        account: smartAccount,
        bundlerTransport: http('http://localhost:4337'),
        paymaster: {
          async getPaymasterStubData(parameters: GetPaymasterStubDataParameters) {
            // Check cache status using new userNullifiersStates mapping
            const userStateKey = getUserStateKey(poolId, smartAccount.address);
            const userNullifiersStateFlags = await paymaster.read.userNullifiersStates([
              userStateKey,
            ]);
            const decodedState = decodeNullifierState(userNullifiersStateFlags);
            const isCached = decodedState.activatedNullifierCount > 0;

            // Construct the UserOperation for the contract call
            const userOp: UserOperation<'0.7'> = {
              sender: parameters.sender,
              nonce: parameters.nonce,
              callData: parameters.callData || '0x',
              callGasLimit: parameters.callGasLimit || 0n,
              verificationGasLimit: parameters.verificationGasLimit || 0n,
              preVerificationGas: parameters.preVerificationGas || 0n,
              maxFeePerGas: parameters.maxFeePerGas || 0n,
              maxPriorityFeePerGas: parameters.maxPriorityFeePerGas || 0n,
              signature: '0x',
            };

            // Pack the UserOperation as required by the contract
            const packedUserOp = getPackedUserOperation(userOp);

            // Use the contract's getPaymasterStubData function with packed UserOp and poolId context
            const encodedContext = encodeAbiParameters(parseAbiParameters('uint256'), [poolId]);
            const stubData = await paymaster.read.getPaymasterStubData([
              packedUserOp,
              encodedContext,
            ]);

            console.log(
              `   Stub data: ${stubData.length} bytes (${isCached ? 'CACHED' : 'ZK PROOF'})`
            );

            return {
              paymaster: paymaster.address,
              paymasterData: stubData,
              paymasterPostOpGasLimit: isCached ? 55000n : 86700n,
            };
          },
          async getPaymasterData(parameters: GetPaymasterDataParameters) {
            const context = parameters.context as Hex;

            // Determine context format by checking the length
            let decodedPoolId: bigint;
            let shouldUseCachedPath = false;

            try {
              if (context.length === 66) {
                // 32 bytes encoded = 66 hex chars (including 0x)
                // Context contains only poolId (cached path)
                decodedPoolId = decodeAbiParameters(parseAbiParameters('uint256'), context)[0];

                // Check if sender is actually cached using new userNullifiersStates mapping
                const userStateKey = getUserStateKey(
                  decodedPoolId,
                  parameters.sender as `0x${string}`
                );
                const userNullifiersStateFlags = await paymaster.read.userNullifiersStates([
                  userStateKey,
                ]);
                const decodedState = decodeNullifierState(userNullifiersStateFlags);
                shouldUseCachedPath = decodedState.activatedNullifierCount > 0;

                console.log(
                  `   Context: poolId only, cached count: ${decodedState.activatedNullifierCount}, shouldUseCachedPath: ${shouldUseCachedPath}`
                );
              } else {
                // Context contains poolId + identity (ZK proof path)
                const [poolId, identityBytes] = decodeAbiParameters(
                  parseAbiParameters('uint256, bytes'),
                  context
                );
                decodedPoolId = poolId;
                shouldUseCachedPath = false;

                console.log(
                  `   Context: poolId + identity, shouldUseCachedPath: ${shouldUseCachedPath}`
                );
              }
            } catch (error) {
              console.error(`   Error decoding context:`, error);
              throw error;
            }

            // If we should use cached path, generate simple cached paymaster data
            if (shouldUseCachedPath) {
              console.log(`   🚀 Using CACHED validation path`);

              // Generate simple cached paymaster data: just poolId + mode (no indices)
              const cachedData = encodePacked(
                ['uint256', 'uint8'],
                [decodedPoolId, 0] // mode 0 = VALIDATION
              );

              return {
                paymaster: paymaster.address,
                paymasterData: cachedData,
              };
            }

            // ZK proof path - we need the identity from context
            console.log(`   🔬 Using ZK PROOF validation path - generating proof...`);

            // Re-decode to get identity (we know it's the full context format)
            const [, identityBytes] = decodeAbiParameters(
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

            return {
              paymaster: paymaster.address,
              paymasterData,
            };
          },
        },
        paymasterContext,
      });

      const request = await smartAccountClient.prepareUserOperation({
        calls: [
          {
            to: '0xF892dc5bBef591D61dD6d75Dfc963c371E723bA4',
            data: '0xdeedbeed',
            value: 0n,
          },
        ],
        paymasterContext,
      });
      console.log({
        paymasterPostOpGasLimit: request.paymasterPostOpGasLimit,
        paymasterVerificationGasLimit: request.paymasterVerificationGasLimit,
        verificationGasLimit: request.verificationGasLimit,
        preVerificationGas: request.preVerificationGas,
        callGasLimit: request.callGasLimit,
      });
      const signature = await smartAccount.signUserOperation(request);

      const beforeTransactionTotalUsersDeposit = await paymaster.read.totalUsersDeposit();
      const beforeTransactionPaymasterBalance = await paymaster.read.getDeposit();

      const userOpHash = await bundlerClient.sendUserOperation({
        entryPointAddress: entryPoint07Address,
        ...request,
        signature,
      });

      const receipt = await bundlerClient.waitForUserOperationReceipt({ hash: userOpHash });

      if (receipt.success) {
        console.log(`✅ Transaction ${i} successful - Hash: ${userOpHash}`);
        successfulTransactions.push(i);

        // Calculate gas consumption
        const gasUsed = receipt.actualGasUsed;

        gasConsumption.push({
          transaction: i,
          gasUsed: Number(gasUsed),
          isZKProof: !isAlreadyCached,
          isCached: isAlreadyCached,
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

        console.log(`   💰 UserOp Gas used: ${gasUsed.toLocaleString()} units`);
        console.log(`   💰 UserOp Gas Cost: ${formatEther(receipt.actualGasCost)} ETH`);
        console.log(`   💰 Tx Gas used: ${receipt.receipt.gasUsed.toLocaleString()} units`);
        console.log(`   💰 Gas used: ${gasUsed.toLocaleString()} units`);
      } else {
        console.log(`❌ Transaction ${i} failed - Hash: ${userOpHash}`);
        failedTransactions.push(i);
      }

      // Check cache status after transaction using new userNullifiersStates mapping
      const userNullifiersStateFlagsAfter = await paymaster.read.userNullifiersStates([
        userStateKey,
      ]);
      const decodedStateAfter = decodeNullifierState(userNullifiersStateFlagsAfter);
      if (decodedStateAfter.activatedNullifierCount > decodedState.activatedNullifierCount) {
        console.log(
          `   ✅ New nullifier cached! Count: ${decodedState.activatedNullifierCount} → ${decodedStateAfter.activatedNullifierCount}`
        );
      }

      // Check pool status
      const poolDeposits = await paymaster.read.getPoolDeposits([poolId]);
      const poolSize = await paymaster.read.getMerkleTreeSize([poolId]);
      console.log(`   Pool size: ${poolSize}, Total deposits: ${formatEther(poolDeposits)} ETH`);

      // const totalUsersDeposit = await paymaster.read.totalUsersDeposit();
      // const paymasterBalance = await paymaster.read.getDeposit();
      const revenue = await paymaster.read.getRevenue();

      console.log(`\n📈 FINAL CONTRACT STATE:`);
      // console.log(`Total users deposit: ${formatEther(totalUsersDeposit)} ETH`);
      // console.log(`Paymaster balance: ${formatEther(paymasterBalance)} ETH`);
      console.log(`💰 Paymaster revenue: ${formatEther(revenue)} ETH`);
    } catch (error) {
      console.log(`❌ Transaction ${i} failed with error:`, error);

      failedTransactions.push(i);
      process.exit(1);
    }
  }

  // Final analysis
  // console.log('\n📊 FINAL SUMMARY:');
  // console.log(`👥 Total identities created: ${identities.length}`);
  // console.log(`✅ Successful transactions: ${successfulTransactions.length}/5`);
  // console.log(`❌ Failed transactions: ${failedTransactions.length}/5`);

  // if (successfulTransactions.length > 0) {
  //   console.log(`Successful transactions: ${successfulTransactions.join(', ')}`);
  // }

  // if (failedTransactions.length > 0) {
  //   console.log(`Failed transactions: ${failedTransactions.join(', ')}`);
  // }

  // Gas consumption analysis
  // console.log('\n⛽ GAS CONSUMPTION ANALYSIS:');
  // const zkProofTransactions = gasConsumption.filter((tx) => tx.isZKProof);
  // const cachedTransactions = gasConsumption.filter((tx) => tx.isCached);

  // if (zkProofTransactions.length > 0) {
  //   const avgZKGas =
  //     zkProofTransactions.reduce((sum, tx) => sum + tx.gasUsed, 0) / zkProofTransactions.length;

  //   console.log(`ZK Proof transactions (${zkProofTransactions.length}):`);
  //   console.log(`  Average gas: ${Math.round(avgZKGas).toLocaleString()} units`);
  // }

  // if (cachedTransactions.length > 0) {
  //   const avgCachedGas =
  //     cachedTransactions.reduce((sum, tx) => sum + tx.gasUsed, 0) / cachedTransactions.length;

  //   console.log(`Cached transactions (${cachedTransactions.length}):`);
  //   console.log(`  Average gas: ${Math.round(avgCachedGas).toLocaleString()} units`);

  //   if (zkProofTransactions.length > 0) {
  //     const gasSavings =
  //       zkProofTransactions.reduce((sum, tx) => sum + tx.gasUsed, 0) / zkProofTransactions.length -
  //       avgCachedGas;

  //     console.log(`💰 SAVINGS with caching:`);
  //     console.log(
  //       `  Gas saved: ${Math.round(gasSavings).toLocaleString()} units (${((gasSavings / (zkProofTransactions.reduce((sum, tx) => sum + tx.gasUsed, 0) / zkProofTransactions.length)) * 100).toFixed(1)}%)`
  //     );
  //   }
  // }

  // Performance analysis
  // if (proofGenerationTimes.length > 0) {
  //   const avgProofTime =
  //     proofGenerationTimes.reduce((a, b) => a + b, 0) / proofGenerationTimes.length;
  //   const minProofTime = Math.min(...proofGenerationTimes);
  //   const maxProofTime = Math.max(...proofGenerationTimes);

  //   console.log('\n⚡ PROOF GENERATION PERFORMANCE:');
  //   console.log(`Average time: ${avgProofTime.toFixed(2)}ms`);
  //   console.log(`Fastest: ${minProofTime}ms`);
  //   console.log(`Slowest: ${maxProofTime}ms`);
  //   console.log(`Total ZK proof transactions: ${proofGenerationTimes.length}`);
  //   console.log(`Total cached transactions: ${gasConsumption.filter((tx) => tx.isCached).length}`);

  //   // Individual timing breakdown
  //   console.log('\n📋 Individual Proof Times:');
  //   let proofIndex = 0;
  //   gasConsumption.forEach((tx) => {
  //     if (tx.isZKProof) {
  //       console.log(
  //         `  Transaction ${tx.transaction}: ${proofGenerationTimes[proofIndex]}ms (ZK PROOF)`
  //       );
  //       proofIndex++;
  //     } else {
  //       console.log(`  Transaction ${tx.transaction}: 0ms (CACHED)`);
  //     }
  //   });
  // }

  // Final contract state
  // const finalPoolSize = await paymaster.read.getMerkleTreeSize([poolId]);
  // const finalPoolDeposits = await paymaster.read.getPoolDeposits([poolId]);
  // const totalUsersDeposit = await paymaster.read.totalUsersDeposit();
  // const paymasterBalance = await paymaster.read.getDeposit();
  // const revenue = await paymaster.read.getRevenue();

  // // Final user state using new mapping
  // const finalUserStateKey = getUserStateKey(poolId, smartAccount.address);
  // const finalUserNullifiersStateFlags = await paymaster.read.userNullifiersStates([
  //   finalUserStateKey,
  // ]);
  // const finalDecodedState = decodeNullifierState(finalUserNullifiersStateFlags);

  // console.log(`\n📈 FINAL CONTRACT STATE:`);
  // console.log(`Pool size: ${finalPoolSize} members`);
  // console.log(`Pool deposits: ${formatEther(finalPoolDeposits)} ETH`);
  // console.log(`Total users deposit: ${formatEther(totalUsersDeposit)} ETH`);
  // console.log(`Paymaster balance: ${formatEther(paymasterBalance)} ETH`);
  // console.log(`💰 Paymaster revenue: ${formatEther(revenue)} ETH`);
  // console.log(`User cached nullifiers: ${finalDecodedState.activatedNullifierCount}`);
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
