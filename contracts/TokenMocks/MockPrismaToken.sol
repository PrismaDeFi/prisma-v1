// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockPrismaToken is ERC20 {
  uint256 private _totalSupply = 100_000_000 * (10 ** 18);

  constructor() ERC20("MockPrisma Token", "MOCK_PRISMA") {
    _mint(msg.sender, _totalSupply);
  }
}
