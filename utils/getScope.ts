import { encodePacked, keccak256 } from 'viem';

const SNARK_SCALAR_FIELD =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;
export function getScope(
  paymasterAddress: `0x${string}`,
  chainId: bigint,
  joiningAmount: bigint
): bigint {
  const encoded = encodePacked(
    ['address', 'uint256', 'uint256'],
    [paymasterAddress, BigInt(chainId), BigInt(joiningAmount)]
  );

  const encodedScope = keccak256(encoded); // returns hex string
  return BigInt(encodedScope) % SNARK_SCALAR_FIELD;
}
