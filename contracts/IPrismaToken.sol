//SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

interface IPrismaToken {
  function getStakedPrisma(address _user) external view returns (uint256);
}
