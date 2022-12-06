//SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

interface IPrismaToken {
  function balanceOf(address account) external view returns (uint256);

  function transfer(address to, uint256 amount) external returns (bool);

  function compoundPrisma(address _staker, uint256 _prismaToCompound) external;

  function getStakedPrisma(address _user) external view returns (uint256);

  function getTotalStakedAmount() external view returns (uint256);
}
