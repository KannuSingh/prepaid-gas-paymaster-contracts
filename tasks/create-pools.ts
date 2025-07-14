// tasks/paymaster.ts
import { task, types } from 'hardhat/config';
import { Address, decodeEventLog, parseEther } from 'viem'; // Import Address type
import { entryPoint07Address } from 'viem/account-abstraction';

task('create-pools', 'Create Prepaid Gas Paymaster group/coupon')
  .addOptionalParam(
    'paymaster',
    'The address of an already deployed GasLimitedPaymaster contract',
    undefined, // default value (optional)
    types.string // This ensures Hardhat validates it as a string
  )
  .setAction(async ({ paymaster: providedPaymasterAddress }, hre) => {
    // This is where your script's main logic goes
    console.log('🚀 Starting Semaphore Gas Paymaster Demo with Gas Tracking...\n');

    // Get wallet client
    const [wallet1] = await hre.viem.getWalletClients();
    console.log(`📱 Using wallet: ${wallet1.account.address}`);

    const publicClient = await hre.viem.getPublicClient();

    // Check wallet balance
    const balance = await publicClient.getBalance({
      address: wallet1.account.address,
    });
    console.log(
      `💰 Wallet balance: ${balance} wei (${parseFloat(balance.toString()) / 1e18} ETH)\n`
    );

    let paymaster;
    const SEMAPHORE_VERIFIER = '0x6C42599435B82121794D835263C846384869502d';
    const POSEIDON_T3 = '0xB43122Ecb241DD50062641f089876679fd06599a';

    if (providedPaymasterAddress) {
      // Basic validation for address format
      if (
        !(providedPaymasterAddress as string).startsWith('0x') ||
        (providedPaymasterAddress as string).length !== 42
      ) {
        console.error(
          '❌ Error: Invalid paymaster address format. Must be a 0x-prefixed 42-character hex string.'
        );
        process.exit(1);
      }
      console.log(`🔍 Using existing GasLimitedPaymaster at: ${providedPaymasterAddress}\n`);
      paymaster = await hre.viem.getContractAt(
        'GasLimitedPaymaster',
        providedPaymasterAddress as Address
      );
    } else {
      // Deploy the paymaster contract
      console.log('📦 Deploying GasLimitedPaymaster...');
      paymaster = await hre.viem.deployContract(
        'GasLimitedPaymaster',
        [entryPoint07Address, SEMAPHORE_VERIFIER],
        {
          libraries: {
            PoseidonT3: POSEIDON_T3,
          },
        }
      );
    }

    console.log(`✅ Paymaster active at: ${paymaster.address}\n`);

    // Create a group
    console.log('👥 Creating Semaphore group...');
    const joiningFees = [
      parseEther('0.001'),
      parseEther('0.0001'),
      // parseEther('0.01'),
      // parseEther('0.05'),
      // parseEther('0.1'),
      // parseEther('0.2'),
      // parseEther('0.5'),
      // parseEther('1'),
    ];
    for (const joiningFee of joiningFees) {
      try {
        const createGroupTxHash = await paymaster.write.createPool([joiningFee]);
        const createGroupTxReceipt = await publicClient.waitForTransactionReceipt({
          hash: createGroupTxHash,
        });

        if (createGroupTxReceipt.status !== 'success') {
          throw new Error('Group creation failed');
        }

        // Get the group ID from the GroupCreated event
        const groupCreatedLog = createGroupTxReceipt.logs.find(
          (log) => log.address.toLowerCase() === paymaster.address.toLowerCase()
        );

        if (!groupCreatedLog) {
          throw new Error('GroupCreated event not found');
        }

        // Decode the group ID from the event
        const { args } = decodeEventLog({
          abi: paymaster.abi,
          eventName: 'PoolCreated',
          topics: groupCreatedLog.topics,
          data: groupCreatedLog.data,
        });

        const poolId = args.poolId as bigint;
        console.log(
          `✅ Pool ${poolId} created successfully! Joining fee: ${parseFloat(joiningFee.toString()) / 1e18} ETH`
        );
      } catch (error) {
        console.error('❌ Failed to create group:', error);
        process.exit(1); // Exit if group creation fails
      }
    }

    console.log('\n✅ Demo completed successfully with gas tracking! 🎉');
  });
