import hre from 'hardhat';
import { Address, encodeAbiParameters, Hex, http, parseEther, PublicClient, toHex } from 'viem';
import { Identity, Group, generateProof } from '@semaphore-protocol/core';
import {
  BundlerClient,
  createBundlerClient,
  entryPoint07Address,
  getUserOperationHash,
  SmartAccount,
  UserOperation,
} from 'viem/account-abstraction';
import { toSimpleSmartAccount } from 'permissionless/accounts';
import { getPackedUserOperation } from 'permissionless/utils';

async function main() {
  console.log('🚀 Starting Multi-Identity Semaphore Gas Paymaster Demo...\n');

  // Initialize multiple identities and group
  let localGroup: Group;
  let groupId: bigint;
  let identities: Identity[] = [];
  let smartAccounts: SmartAccount[] = [];

  // Get wallet clients
  const walletClients = await hre.viem.getWalletClients();
  const [wallet1, wallet2, wallet3] = walletClients;

  console.log(`📱 Using wallets:`);
  console.log(`  - Wallet 1: ${wallet1.account.address}`);
  console.log(`  - Wallet 2: ${wallet2.account.address}`);
  console.log(`  - Wallet 3: ${wallet3.account.address}`);

  // Generate multiple identities from signatures
  console.log('\n🔐 Generating multiple identities...');

  const identity1 = new Identity(
    await wallet1.signMessage({ message: 'Identity 1 for Multi-UserOp Demo' })
  );
  const identity2 = new Identity(
    await wallet2.signMessage({ message: 'Identity 2 for Multi-UserOp Demo' })
  );
  const identity3 = new Identity(
    await wallet3.signMessage({ message: 'Identity 3 for Multi-UserOp Demo' })
  );
  const dummyIdentity = new Identity(
    await wallet1.signMessage({ message: 'Dummy Identity for Group Setup' })
  );

  identities = [identity1, identity2, identity3];

  // Create local group with all identities
  localGroup = new Group([
    dummyIdentity.commitment,
    identity1.commitment,
    identity2.commitment,
    identity3.commitment,
  ]);

  console.log(`✅ Generated ${identities.length + 1} identities:`);
  console.log(`  - Dummy ID: ${dummyIdentity.commitment}`);
  identities.forEach((id, index) => {
    console.log(`  - Identity ${index + 1}: ${id.commitment}`);
  });

  const publicClient = await hre.viem.getPublicClient();

  // Check initial wallet balances
  await checkBalances('Initial Wallet Balances', [], walletClients, publicClient);

  // Check network
  const chainId = await publicClient.getChainId();
  console.log(`🌐 Network Chain ID: ${chainId} ${chainId === 31337 ? '(Local Hardhat)' : ''}`);

  // Deploy the paymaster contract
  console.log('\n📦 Deploying GasLimitedPaymaster on Base Sepolia...');
  const SEMAPHORE_VERIFIER = '0x6C42599435B82121794D835263C846384869502d';
  const POSEIDON_T3 = '0xB43122Ecb241DD50062641f089876679fd06599a';

  const paymaster = await hre.viem.deployContract(
    'GasLimitedPaymaster',
    [entryPoint07Address, SEMAPHORE_VERIFIER],
    {
      libraries: {
        PoseidonT3: POSEIDON_T3,
      },
    }
  );

  console.log(`✅ Paymaster deployed at: ${paymaster.address}`);

  // Check balances after deployment
  await checkBalances('Balances After Paymaster Deployment', [], walletClients, publicClient);

  // Create a group with higher joining fee to support multiple operations
  console.log('\n👥 Creating Semaphore group...');
  const joiningFee = parseEther('0.05'); // Higher fee for multiple operations

  try {
    const createGroupTxHash = await paymaster.write.createPool([joiningFee]);
    await trackTransactionCost(createGroupTxHash, 'Group Creation', publicClient);

    console.log(
      `✅ Group created successfully! Joining fee: ${parseFloat(joiningFee.toString()) / 1e18} ETH`
    );
  } catch (error) {
    console.error('❌ Failed to create group:', error);
    return;
  }

  groupId = 1n; // First group has ID 1 (poolCounter starts from 0, first pool gets ID 1)

  // Add all identities to group in batch
  console.log('\n🔗 Adding all identities to group...');
  try {
    const allCommitments = [dummyIdentity.commitment, ...identities.map((id) => id.commitment)];
    const totalFee = joiningFee * BigInt(allCommitments.length);

    console.log(
      `💸 Total joining fee: ${parseFloat(totalFee.toString()) / 1e18} ETH for ${allCommitments.length} members`
    );

    const joinGroupTxHash = await paymaster.write.addMembers([groupId, allCommitments], {
      value: totalFee,
    });
    await trackTransactionCost(joinGroupTxHash, 'Member Addition', publicClient);

    console.log(`✅ Added ${allCommitments.length} identities to group successfully!`);
  } catch (error) {
    console.error('❌ Failed to add identities:', error);
    return;
  }

  // Check balances after deposits
  await checkBalances('Balances After Group Deposits', [], walletClients, publicClient);

  // Check initial paymaster balance
  const initialBalance = await paymaster.read.getDeposit();
  console.log(`💰 Initial paymaster balance: ${parseFloat(initialBalance.toString()) / 1e18} ETH`);

  // Create smart accounts for each wallet with UNIQUE addresses
  console.log('\n🏭 Creating smart accounts with unique addresses...');
  for (let i = 0; i < 3; i++) {
    const account = await toSimpleSmartAccount({
      owner: walletClients[i],
      client: publicClient,
      entryPoint: {
        address: entryPoint07Address,
        version: '0.7',
      },
      index: BigInt(i + 1), // ✅ UNIQUE SALT FOR DIFFERENT ADDRESSES
    });
    smartAccounts.push(account);
    console.log(`✅ Smart account ${i + 1} created: ${account.address}`);
  }

  // Verify all accounts have different addresses
  const addresses = smartAccounts.map((account) => account.address);
  const uniqueAddresses = new Set(addresses);

  if (uniqueAddresses.size !== addresses.length) {
    console.error('❌ ERROR: Some smart accounts have duplicate addresses!');
    console.log('Addresses:', addresses);
    throw new Error('Smart accounts must have unique addresses');
  }

  console.log('✅ All smart accounts have unique addresses');

  // Check smart account balances
  await checkBalances('Smart Account Balances', smartAccounts, walletClients, publicClient);

  // Create bundler client
  console.log('\n🔗 Connecting to bundler...');
  const bundlerClient = createBundlerClient({
    client: publicClient,
    transport: http('http://localhost:4337'),
  });

  // Test bundler connection
  try {
    const chainId = await bundlerClient.getChainId();
    console.log(`✅ Connected to bundler on chain ${chainId}`);
  } catch (error) {
    console.error(
      '❌ Failed to connect to bundler. Make sure bundler is running on localhost:4337'
    );
    return;
  }

  // Execute multiple user operations
  console.log('\n🚀 Executing multiple user operations...');

  const results = [];
  const nullifiers: bigint[] = []; // Store nullifiers for final summary

  for (let i = 0; i < identities.length; i++) {
    const identity = identities[i];
    const account = smartAccounts[i];

    console.log(`\n--- User Operation ${i + 1} (Identity ${i + 1}) ---`);

    try {
      // Get balance before operation
      const balanceBefore = await paymaster.read.getDeposit();
      console.log(
        `💰 Paymaster balance before: ${parseFloat(balanceBefore.toString()) / 1e18} ETH`
      );

      // Execute user operation (this will return the nullifier)
      const { receipt, nullifier } = await executeUserOperation(
        account,
        identity,
        localGroup,
        groupId,
        paymaster,
        bundlerClient,
        publicClient,
        i + 1
      );

      // Store nullifier for final summary
      nullifiers.push(nullifier);

      // Get balance after operation
      const balanceAfter = await paymaster.read.getDeposit();
      const gasCostFromBalance = balanceBefore - balanceAfter;
      console.log(`💰 Paymaster balance after: ${parseFloat(balanceAfter.toString()) / 1e18} ETH`);
      console.log(
        `💸 Gas cost (from balance): ${parseFloat(gasCostFromBalance.toString()) / 1e18} ETH`
      );

      // Check nullifier gas usage after operation
      const nullifierGasUsed = await paymaster.read.poolMembersGasData([nullifier]);
      console.log(`🔑 Nullifier (${nullifier}) gas used: ${nullifierGasUsed} wei`);
      console.log(
        `📊 Gas used this operation: ${parseFloat(nullifierGasUsed.toString()) / 1e18} ETH`
      );

      // Validate gas cost consistency
      const receiptGasCost = receipt.actualGasCost || 0n;
      console.log(`📄 Receipt gas cost: ${receiptGasCost} wei`);

      if (gasCostFromBalance === receiptGasCost && nullifierGasUsed === receiptGasCost) {
        console.log(`✅ Gas tracking consistent across all sources`);
      } else {
        console.log(`⚠️  Gas tracking inconsistency detected:`);
        console.log(`  - Balance change: ${gasCostFromBalance}`);
        console.log(`  - Receipt: ${receiptGasCost}`);
        console.log(`  - Nullifier: ${nullifierGasUsed}`);
      }

      results.push({
        userOp: i + 1,
        identity: identity.commitment.toString(),
        nullifier: nullifier.toString(),
        account: account.address,
        success: receipt.success,
        gasCost: receiptGasCost,
        balanceChange: gasCostFromBalance,
        nullifierGasUsed: nullifierGasUsed,
      });

      console.log(`✅ User Operation ${i + 1} completed successfully!`);
    } catch (error) {
      console.error(`❌ User Operation ${i + 1} failed:`, error);
      results.push({
        userOp: i + 1,
        identity: identity.commitment.toString(),
        nullifier: 'N/A',
        account: account.address,
        success: false,
        error: error instanceof Error ? error.message : String(error),
      });
    }

    // Wait a bit between operations
    if (i < identities.length - 1) {
      console.log('⏳ Waiting 2 seconds before next operation...');
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
  }

  // Final summary
  console.log('\n📊 === FINAL SUMMARY ===');
  const finalBalance = await paymaster.read.getDeposit();
  const totalGasUsed = initialBalance - finalBalance;

  console.log(`💰 Initial paymaster balance: ${parseFloat(initialBalance.toString()) / 1e18} ETH`);
  console.log(`💰 Final paymaster balance: ${parseFloat(finalBalance.toString()) / 1e18} ETH`);
  console.log(`💸 Total gas consumed: ${parseFloat(totalGasUsed.toString()) / 1e18} ETH`);

  console.log(`\n📋 Operation Results:`);
  results.forEach((result, index) => {
    console.log(`  UserOp ${result.userOp}: ${result.success ? '✅ Success' : '❌ Failed'}`);
    if (result.success) {
      console.log(`    Gas Cost: ${parseFloat((result.gasCost || 0n).toString()) / 1e18} ETH`);
      console.log(
        `    Balance Change: ${parseFloat((result.balanceChange || 0n).toString()) / 1e18} ETH`
      );
      console.log(
        `    Nullifier Gas: ${parseFloat((result.nullifierGasUsed || 0n).toString()) / 1e18} ETH`
      );
      console.log(`    Nullifier: ${result.nullifier}`);
    } else {
      console.log(`    Error: ${result.error}`);
    }
  });

  // Check remaining gas allowances using the actual nullifiers
  console.log(`\n🔑 Remaining Gas Allowances:`);
  for (let i = 0; i < nullifiers.length; i++) {
    const nullifier = nullifiers[i];
    const gasUsed = await paymaster.read.poolMembersGasData([nullifier]);
    const remaining = joiningFee - gasUsed;
    console.log(`  Identity ${i + 1} (Nullifier: ${nullifier}):`);
    console.log(`    Used: ${parseFloat(gasUsed.toString()) / 1e18} ETH`);
    console.log(`    Remaining: ${parseFloat(remaining.toString()) / 1e18} ETH`);
  }

  // Final balance check
  await checkBalances('Final Wallet Balances', smartAccounts, walletClients, publicClient);

  console.log('\n✅ Multi-Identity Demo completed successfully! 🎉');
}

async function executeUserOperation(
  account: SmartAccount,
  identity: Identity,
  group: Group,
  groupId: bigint,
  paymaster: any,
  bundlerClient: BundlerClient,
  publicClient: PublicClient,
  operationNumber: number
) {
  console.log(`🛠️  Preparing user operation ${operationNumber}...`);

  // Prepare user operation with WORKING target (paymaster address)
  let userOperation = await prepareUserOp({
    account,
    calls: [
      {
        to: '0xF892dc5bBef591D61dD6d75Dfc963c371E723bA4', // ✅ this is an EOA (guaranteed to exist)
        data: '0xdeedbeed', // random message
      },
    ],
  });

  // Set gas prices
  const { maxFeePerGas, maxPriorityFeePerGas } = await publicClient.estimateFeesPerGas();
  userOperation.maxFeePerGas = maxFeePerGas;
  userOperation.maxPriorityFeePerGas = maxPriorityFeePerGas;

  // Set hardcoded gas limits
  userOperation.callGasLimit = 100000n;
  userOperation.verificationGasLimit = 2000000n;
  userOperation.preVerificationGas = 100000n;

  // Set paymaster fields
  userOperation.paymaster = paymaster.address;
  userOperation.paymasterVerificationGasLimit = 1000000n;
  userOperation.paymasterPostOpGasLimit = 300000n;
  userOperation.paymasterData = '0x';

  // Generate message hash for proof
  const packedUserOpForHash = getPackedUserOperation(userOperation);
  const messageHashFromContract = await paymaster.read.getMessageHash([packedUserOpForHash]);

  console.log(`📝 Message hash: ${BigInt(messageHashFromContract)}`);

  // Generate Semaphore proof
  console.log(`🔐 Generating proof for identity ${identity.commitment}...`);

  const proof = await generateProof(identity, group, BigInt(messageHashFromContract), groupId);

  if (proof.points.length !== 8) {
    throw new Error(`Expected 8 proof points, got ${proof.points.length}`);
  }

  const semaphoreProof = {
    merkleTreeDepth: BigInt(proof.merkleTreeDepth),
    merkleTreeRoot: BigInt(proof.merkleTreeRoot),
    nullifier: BigInt(proof.nullifier),
    message: BigInt(proof.message),
    scope: BigInt(proof.scope),
    points: proof.points as readonly [
      bigint,
      bigint,
      bigint,
      bigint,
      bigint,
      bigint,
      bigint,
      bigint,
    ],
  };

  console.log(`🔑 Generated nullifier: ${semaphoreProof.nullifier}`);

  // Build paymaster data with size validation
  const paymasterData = await generatePaymasterData(groupId, semaphoreProof, paymaster);
  userOperation.paymasterData = paymasterData;

  console.log(`📦 Paymaster data built (${paymasterData.length / 2 - 1} bytes)`);

  // Verify expected paymaster data size
  const expectedSize = 480; // 32 (config) + 32 (poolId) + 416 (proof)
  const actualSize = paymasterData.length / 2 - 1;
  if (actualSize !== expectedSize) {
    throw new Error(`Wrong paymaster data size: ${actualSize} (expected ${expectedSize})`);
  }

  // Pre-submission validation
  console.log('\n=== PRE-SUBMISSION VALIDATION ===');

  // Check account deployment
  const accountCode = await publicClient.getBytecode({ address: account.address });
  console.log(`🏭 Account deployed: ${accountCode ? 'YES' : 'NO'}`);

  // Check account balance
  const accountBalance = await publicClient.getBalance({ address: account.address });
  console.log(`💰 Account balance: ${accountBalance} wei`);

  // Check if target contract exists (should be paymaster)
  const targetCode = await publicClient.getBytecode({ address: paymaster.address });
  console.log(`🎯 Target contract exists: ${targetCode ? 'YES' : 'NO'}`);

  // Verify proof validation
  const isValidProof = await paymaster.read.verifyProof([semaphoreProof]);
  if (!isValidProof) {
    throw new Error('Proof validation failed!');
  }
  console.log(`✅ Final proof validation: PASSED`);

  // Check paymaster balance
  const paymasterBalance = await paymaster.read.getDeposit();
  console.log(`💳 Paymaster balance: ${paymasterBalance} wei`);

  // Sign user operation
  const signature = await account.signUserOperation(userOperation);
  userOperation.signature = signature;
  console.log(`✍️  User operation signed`);

  // Log final user operation details
  console.log('\n=== FINAL USER OPERATION ===');
  console.log({
    sender: userOperation.sender,
    nonce: userOperation.nonce.toString(),
    paymaster: userOperation.paymaster,
    paymasterDataLength: userOperation.paymasterData.length / 2 - 1,
    callGasLimit: userOperation.callGasLimit.toString(),
    verificationGasLimit: userOperation.verificationGasLimit.toString(),
    maxFeePerGas: userOperation.maxFeePerGas.toString(),
  });

  // Submit to bundler
  console.log(`\n🚀 Submitting to bundler...`);
  const userOpHash = await bundlerClient.sendUserOperation({
    entryPointAddress: entryPoint07Address,
    ...userOperation,
  });

  console.log(`📦 UserOp submitted: ${userOpHash}`);
  console.log(`⏳ Waiting for receipt...`);

  const receipt = await bundlerClient.waitForUserOperationReceipt({
    hash: userOpHash,
    timeout: 60000,
  });

  // Detailed receipt analysis
  console.log('\n=== RECEIPT ANALYSIS ===');
  console.log(`✅ Success: ${receipt.success}`);
  console.log(`📄 Reason: ${receipt.reason || 'N/A'}`);
  console.log(`⛽ Actual gas cost: ${receipt.actualGasCost?.toString() || '0'}`);
  console.log(`⛽ Actual gas used: ${receipt.actualGasUsed?.toString() || '0'}`);

  if (receipt.logs) {
    console.log(`📜 Number of logs: ${receipt.logs.length}`);
    receipt.logs.forEach((log: any, index: any) => {
      console.log(`📜 Log ${index}: ${log.address} - ${log.topics.length} topics`);
    });
  }

  if (!receipt.success) {
    throw new Error(`UserOp failed: ${receipt.reason}`);
  }

  return { receipt, nullifier: semaphoreProof.nullifier };
}

async function prepareUserOp(args: {
  account: SmartAccount;
  calls: { to: Address; value?: bigint; data: Hex }[];
}): Promise<UserOperation<'0.7'>> {
  const { account, calls } = args;
  const callData = await account.encodeCalls(calls);
  const { factory, factoryData } = await account.getFactoryArgs();

  return {
    sender: account.address,
    nonce: await account.getNonce(),
    factory,
    factoryData,
    callData: callData,
    callGasLimit: 0n,
    verificationGasLimit: 0n,
    preVerificationGas: 0n,
    maxFeePerGas: 0n,
    maxPriorityFeePerGas: 0n,
    paymasterVerificationGasLimit: 0n,
    paymasterPostOpGasLimit: 0n,
    signature: '0x',
  };
}

async function generatePaymasterData(
  groupId: bigint,
  semaphoreProof: {
    merkleTreeDepth: bigint;
    merkleTreeRoot: bigint;
    nullifier: bigint;
    message: bigint;
    scope: bigint;
    points: readonly [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint];
  },
  paymaster: any
): Promise<Hex> {
  // Get latest valid root info for proper merkle root index
  const latestRootInfo = await paymaster.read.getLatestValidRootInfo([groupId]);
  const merkleRootIndex = latestRootInfo[1]; // Use the actual root index
  
  // Config: merkleRootIndex (32 bits) + mode (32 bits, 0 = VALIDATION) + 28 bytes reserved  
  const config = BigInt(merkleRootIndex) | (BigInt(0) << 32n); // mode = 0 for VALIDATION
  const configBytes = encodeAbiParameters([{ type: 'uint256' }], [config]);
  console.log(`📏 Config bytes length: ${configBytes.length / 2 - 1}`); // Should be 32

  // Encode group ID (32 bytes)
  const groupIdBytes = encodeAbiParameters([{ type: 'uint256' }], [groupId]);
  console.log(`📏 GroupId bytes length: ${groupIdBytes.length / 2 - 1}`); // Should be 32

  // Encode Semaphore proof (416 bytes)
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
    [semaphoreProof]
  );
  console.log(`📏 Proof bytes length: ${proofBytes.length / 2 - 1}`); // Should be 416

  // Combine: config + groupId + proof (remove 0x prefix from subsequent bytes)
  const result = (configBytes + groupIdBytes.slice(2) + proofBytes.slice(2)) as Hex;
  console.log(`📏 Total paymaster data length: ${result.length / 2 - 1}`); // Should be 480

  return result;
}

// Helper function to check balances
async function checkBalances(
  label: string,
  smartAccounts: SmartAccount[],
  walletClients: any[],
  publicClient: any
) {
  console.log(`\n💰 ${label}:`);

  for (let i = 0; i < walletClients.length; i++) {
    const balance = await publicClient.getBalance({
      address: walletClients[i].account.address,
    });
    console.log(`  - Wallet ${i + 1}: ${parseFloat(balance.toString()) / 1e18} ETH`);
  }

  if (smartAccounts.length > 0) {
    console.log(`💳 Smart Account Balances:`);
    for (let i = 0; i < smartAccounts.length; i++) {
      const balance = await publicClient.getBalance({
        address: smartAccounts[i].address,
      });
      console.log(`  - Account ${i + 1}: ${parseFloat(balance.toString()) / 1e18} ETH`);
    }
  }
}

// Helper function to track transaction costs
async function trackTransactionCost(txHash: string, description: string, publicClient: any) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
  const gasCost = receipt.gasUsed * receipt.effectiveGasPrice;

  console.log(`💸 ${description} Cost:`);
  console.log(`  - Gas used: ${receipt.gasUsed}`);
  console.log(`  - Gas price: ${receipt.effectiveGasPrice}`);
  console.log(`  - Total cost: ${parseFloat(gasCost.toString()) / 1e18} ETH`);

  return gasCost;
}

main().catch((error) => {
  console.error('💥 Script failed:', error);
  process.exitCode = 1;
});
