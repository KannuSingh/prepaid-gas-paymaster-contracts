import { encodeAbiParameters, keccak256, parseAbiParameters } from 'viem';
import { PackedUserOperation } from 'viem/account-abstraction';

const PAYMASTER_DATA_OFFSET = 52;
export function getMessageHash(
  userOp: PackedUserOperation,
  chainId: bigint,
  entryPointAddress: `0x${string}`
): `0x${string}` {
  const encoded = encodeAbiParameters(
    parseAbiParameters('address, uint256, bytes32, bytes32, uint256, uint256, uint256, bytes32'),
    [
      userOp.sender,
      userOp.nonce,
      keccak256(userOp.initCode),
      keccak256(userOp.callData),
      BigInt(userOp.accountGasLimits),
      BigInt(userOp.preVerificationGas),
      BigInt(userOp.gasFees),
      keccak256(userOp.paymasterAndData.slice(0, 2 + PAYMASTER_DATA_OFFSET * 2) as `0x${string}`),
    ]
  );

  const encodeWithChainAndEntryPoint = encodeAbiParameters(
    parseAbiParameters('bytes32, address, uint256'),
    [keccak256(encoded), entryPointAddress, chainId]
  );
  return keccak256(encodeWithChainAndEntryPoint);
}
