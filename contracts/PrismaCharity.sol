// ██████╗ ██████╗ ██╗███████╗███╗   ███╗ █████╗     ███████╗██╗███╗   ██╗ █████╗ ███╗   ██╗ ██████╗███████╗
// ██╔══██╗██╔══██╗██║██╔════╝████╗ ████║██╔══██╗    ██╔════╝██║████╗  ██║██╔══██╗████╗  ██║██╔════╝██╔════╝
// ██████╔╝██████╔╝██║███████╗██╔████╔██║███████║    █████╗  ██║██╔██╗ ██║███████║██╔██╗ ██║██║     █████╗
// ██╔═══╝ ██╔══██╗██║╚════██║██║╚██╔╝██║██╔══██║    ██╔══╝  ██║██║╚██╗██║██╔══██║██║╚██╗██║██║     ██╔══╝
// ██║     ██║  ██║██║███████║██║ ╚═╝ ██║██║  ██║    ██║     ██║██║ ╚████║██║  ██║██║ ╚████║╚██████╗███████╗
// ╚═╝     ╚═╝  ╚═╝╚═╝╚══════╝╚═╝     ╚═╝╚═╝  ╚═╝    ╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝╚══════╝

// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";

contract BETA_PrismaCharity is Ownable {
  address private prismaProxy = 0xB7ED90F0BE22c7942133404474c7c41199C08a2D;

  function retrieveERC20(
    address token,
    address dst,
    uint256 amount
  ) external onlyOwner {
    uint256 balance = IERC20(token).balanceOf(address(this));
    if (token == prismaProxy) {
      require(balance - amount > (200_000 * (10 ** 18)));
    }
    IERC20(token).transfer(dst, amount);
  }

  function retrieveBNB(address dst) external onlyOwner returns (bool success) {
    uint256 balance = address(this).balance;
    (success, ) = payable(address(dst)).call{value: balance}("");
    require(success, "Could not retrieve");
  }
}
