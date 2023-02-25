//SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

interface IPrismaToken {
  function balanceOf(address account) external view returns (uint256);

  function transfer(address to, uint256 amount) external returns (bool);

  function compoundPrisma(address _staker, uint256 _prismaToCompound) external;

  function getMultisig() external view returns (address);

  function getTreasury() external view returns (address);

  function getBurn() external view returns (address);

  function getStakedPrisma(address _user) external view returns (uint256);

  function getTotalStakedAmount() external view returns (uint256);

  function getSellLiquidityFee() external view returns (uint256);

  function getSellTreasuryFee() external view returns (uint256);

  function getSellBurnFee() external view returns (uint256);

  function getTotalSellFees() external view returns (uint256);
}
