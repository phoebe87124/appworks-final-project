// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.17;

interface ICToken {
  function isCToken() external view returns (bool);
  function symbol() external view returns (string calldata);
  function totalBorrows() external view returns (uint);
  function getAccountSnapshot(address account) external view returns (uint, uint, uint, uint);
  function borrowBalanceStored(address account) external view returns (uint);
  function exchangeRateStored() external view returns (uint);
}