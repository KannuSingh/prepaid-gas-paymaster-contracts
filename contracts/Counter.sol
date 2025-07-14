// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Counter {
    uint256 public count;

    event CounterIncremented(uint256 newCount, address indexed user);

    function increment() public {
        count += 1;
        emit CounterIncremented(count, msg.sender);
    }
}
