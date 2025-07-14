// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library BaseErrors {
    error InvalidEntryPoint();
    error InvalidVerifierAddress();
    error UnauthorizedCaller();
    error WithdrawalNotAllowed();
}
