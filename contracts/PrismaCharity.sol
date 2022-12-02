// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";

contract PrismaCharity is Ownable {
  address private prismaProxy = address(0x0); // placeholder

  function retrieveERC20(
    address token,
    address dst,
    uint256 amount
  ) external onlyOwner {
    uint256 balance = IERC20(token).balanceOf(address(this));
    if (token == prismaProxy) {
      require(balance - amount > (2_000_000 * (10 ** 18)));
    }
    IERC20(token).transfer(dst, amount);
  }

  function retrieveBNB(address dst) external onlyOwner returns (bool success) {
    uint256 balance = address(this).balance;
    (success, ) = payable(address(dst)).call{value: balance}("");
    require(success, "Could not retrieve");
  }
}
