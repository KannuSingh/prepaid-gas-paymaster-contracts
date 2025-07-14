// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library PaymasterEncodingErrors {
    error InvalidConfigFormat(uint256 config);
    error InvalidDataLength(uint256 provided, uint256 expected);
    error InvalidMode(uint8 mode);
}
