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

async function main() {
  const [wallet1] = await hre.viem.getWalletClients();
  const publicClient = await hre.viem.getPublicClient();

  const paymaster = await hre.viem.deployContract(
    'GasLimitedPaymaster',
    [entryPoint07Address, '0x6C42599435B82121794D835263C846384869502d'],
    {
      libraries: { PoseidonT3: '0xB43122Ecb241DD50062641f089876679fd06599a' },
    }
  );

  const joiningFee = parseEther('0.01');

  await paymaster.write.createPool([joiningFee]);
  const poolId = 1n;

  // Initial setup with dummy identity
  const dummyId = new Identity(await wallet1.signMessage({ message: 'dummy' }));
  let localPool = new Group([dummyId.commitment]);

  await paymaster.write.addMember([poolId, dummyId.commitment], { value: joiningFee });

  const smartAccount = await toSimpleSmartAccount({
    owner: wallet1,
    client: publicClient,
    entryPoint: { address: entryPoint07Address, version: '0.7' },
  });

  const bundlerClient = createBundlerClient({
    client: publicClient,
    transport: http('http://localhost:4337'),
  });

  // Track all identities created
  const identities = [];
  const successfulTransactions = [];
  const failedTransactions = [];
  const proofGenerationTimes: number[] = []; // Track proof generation times

  // Submit UserOp 15 times with new identities
  for (let i = 1; i <= 100; i++) {
    try {
      console.log(`\n🆔 Creating new identity ${i}/15...`);

      // Create new identity for this iteration
      const newIdentity = new Identity(await wallet1.signMessage({ message: `identity-${i}` }));
      identities.push(newIdentity);

      // Add new identity to the pool
      console.log(`💰 Adding identity ${i} to pool...`);
      const addMemberTx = await paymaster.write.addMember([poolId, newIdentity.commitment], {
        value: joiningFee,
      });

      // Wait for the transaction to be mined and state to be updated
      console.log(`⏳ Waiting for member addition to be confirmed...`);
      await new Promise((resolve) => setTimeout(resolve, 2000)); // 2 second delay

      // Add new identity to local group for proof generation
      localPool.addMember(newIdentity.commitment);

      // Additional verification - check if the root history is updated
      const rootHistoryInfo = await paymaster.read.getPoolRootHistoryInfo([poolId]);
      console.log(
        `   Root history count: ${rootHistoryInfo[1]}, Current index: ${rootHistoryInfo[0]}`
      );

      console.log(`🚀 Submitting UserOp ${i}/15 with new identity...`);

      // Create smart account client with the new identity context
      const smartAccountClient = createSmartAccountClient({
        client: publicClient,
        account: smartAccount,
        bundlerTransport: http('http://localhost:4337'),
        paymaster: {
          async getPaymasterStubData(parameters: GetPaymasterStubDataParameters) {
            const encodedContext = encodeAbiParameters(parseAbiParameters('uint256'), [poolId]);
            const stubData = await paymaster.read.getPaymasterStubData([encodedContext]);
            return {
              paymaster: paymaster.address,
              paymasterData: stubData,
              paymasterPostOpGasLimit: 65000n,
            };
          },
          async getPaymasterData(parameters: GetPaymasterDataParameters) {
            const [decodedPoolId, identityBytes] = decodeAbiParameters(
              parseAbiParameters('uint256, bytes'),
              parameters.context as Hex
            );

            const identityStr = hexToString(identityBytes);
            const identity = Identity.import(identityStr);

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

            // Debug logging
            const rootHistoryInfo = await paymaster.read.getPoolRootHistoryInfo([decodedPoolId]);
            console.log(
              `   Debug - Pool ${decodedPoolId}: latestRoot=${latestRootInfo[0]}, rootIndex=${latestRootInfo[1]}, historyCount=${rootHistoryInfo[1]}`
            );

            if (latestRootInfo[1] >= rootHistoryInfo[1]) {
              console.log(
                `   Warning: rootIndex ${latestRootInfo[1]} >= historyCount ${rootHistoryInfo[1]}`
              );
              // Use the most recent valid index
              const validIndex = rootHistoryInfo[1] > 0 ? rootHistoryInfo[1] - 1 : 0;
              console.log(`   Using validIndex: ${validIndex}`);
              latestRootInfo[1] = validIndex;
            }

            // 🔬 Start timing proof generation
            console.log(`   🔬 Starting proof generation...`);
            const proofStartTime = Date.now();

            const proof = await generateProof(identity, localPool, BigInt(msgHash), decodedPoolId);

            const proofEndTime = Date.now();
            const proofGenerationTime = proofEndTime - proofStartTime;
            console.log(`   ⚡ Proof generated in ${proofGenerationTime}ms`);

            // Store timing for analysis
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
        paymasterContext: encodeAbiParameters(parseAbiParameters('uint256, bytes'), [
          poolId,
          toHex(newIdentity.export()),
        ]),
      });

      const request = await smartAccountClient.prepareUserOperation({
        calls: [
          {
            to: '0xF892dc5bBef591D61dD6d75Dfc963c371E723bA4',
            data: '0xdeedbeed',
            value: 0n,
          },
        ],
        paymasterContext: encodeAbiParameters(parseAbiParameters('uint256, bytes'), [
          poolId,
          toHex(newIdentity.export()),
        ]),
      });

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
      } else {
        console.log(`❌ Transaction ${i} failed - Hash: ${userOpHash}`);
        failedTransactions.push(i);
      }

      // Calculate nullifier to check gas usage
      const scope = BigInt(keccak256(toHex(BigInt(poolId), { size: 32 }))) >> BigInt(8);
      const secret = newIdentity.secretScalar;
      const nullifier = poseidon2([scope, secret]);

      // Check gas usage for this specific identity
      const gasUsed = await paymaster.read.poolMembersGasData([BigInt(nullifier)]);
      const remainingGas = joiningFee - gasUsed;
      console.log(`   Identity ${i} - Gas used: ${gasUsed}, Remaining: ${remainingGas}`);

      // Check pool status
      const poolDeposits = await paymaster.read.getPoolDeposits([poolId]);
      const poolSize = await paymaster.read.getMerkleTreeSize([poolId]);
      console.log(`   Pool size: ${poolSize}, Total deposits: ${poolDeposits}`);
    } catch (error) {
      console.log(`❌ Transaction ${i} failed with error:`, error);
      failedTransactions.push(i);
    }
  }

  // Calculate proof generation statistics
  const avgProofTime =
    proofGenerationTimes.reduce((a, b) => a + b, 0) / proofGenerationTimes.length;
  const minProofTime = Math.min(...proofGenerationTimes);
  const maxProofTime = Math.max(...proofGenerationTimes);

  // Final summary
  console.log('\n📊 Final Summary:');
  console.log(`👥 Total identities created: ${identities.length}`);
  console.log(`✅ Successful transactions: ${successfulTransactions.length}/15`);
  console.log(`❌ Failed transactions: ${failedTransactions.length}/15`);

  if (successfulTransactions.length > 0) {
    console.log(`Successful transactions: ${successfulTransactions.join(', ')}`);
  }

  if (failedTransactions.length > 0) {
    console.log(`Failed transactions: ${failedTransactions.join(', ')}`);
  }

  // Proof generation performance analysis
  console.log('\n⚡ Proof Generation Performance:');
  console.log(`Average time: ${avgProofTime.toFixed(2)}ms`);
  console.log(`Fastest: ${minProofTime}ms`);
  console.log(`Slowest: ${maxProofTime}ms`);
  console.log(`Total proof generation time: ${proofGenerationTimes.reduce((a, b) => a + b, 0)}ms`);

  // Individual timing breakdown
  console.log('\n📋 Individual Proof Times:');
  proofGenerationTimes.forEach((time, index) => {
    console.log(`  Transaction ${index + 1}: ${time}ms`);
  });

  const finalPoolSize = await paymaster.read.getMerkleTreeSize([poolId]);
  const finalPoolDeposits = await paymaster.read.getPoolDeposits([poolId]);
  const totalUsersDeposit = await paymaster.read.totalUsersDeposit();
  const paymasterBalance = await paymaster.read.getDeposit();
  const revenue = await paymaster.read.getRevenue();

  console.log(`\n📈 Final Pool Stats:`);
  console.log(`Pool size: ${finalPoolSize} members`);
  console.log(`Pool deposits: ${finalPoolDeposits} wei ${formatEther(finalPoolDeposits)} ETH`);
  console.log(
    `Total users deposit tracked: ${totalUsersDeposit} wei ${formatEther(totalUsersDeposit)} ETH`
  );
  console.log(`Paymaster Balance: ${paymasterBalance} wei ${formatEther(paymasterBalance)} ETH`);
  console.log(`💰 Paymaster revenue: ${revenue} wei: ${formatEther(revenue)} ETH`);
  console.log(
    `💰 Paymaster revenue: ${paymasterBalance - totalUsersDeposit} wei ${formatEther(paymasterBalance - totalUsersDeposit)} ETH`
  );
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
  // Config: merkleRootIndex (32 bits) + mode (32 bits, 0 = VALIDATION) + 28 bytes reserved
  const config = BigInt(merkleRootIndex) | (BigInt(0) << 32n); // mode = 0 for VALIDATION
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
