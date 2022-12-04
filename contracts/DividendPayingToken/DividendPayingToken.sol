//SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./IDividendPayingToken.sol";
import "./IDividendPayingTokenOptional.sol";
import "../IPrismaToken.sol";

/**
 * @title Dividend-Paying Token
 * @dev A mintable ERC20 token that allows anyone to pay and distribute ether
 *  to token holders as dividends and allows token holders to withdraw their dividends.
 */
contract DividendPayingToken is
  ERC20Upgradeable,
  IDividendPayingToken,
  IDividendPayingTokenOptional,
  OwnableUpgradeable
{
  /**
   * @dev With `magnitude`, we can properly distribute dividends even if the amount of received ether is small.
   */
  uint256 internal constant magnitude = 2 ** 128;

  uint256 public magnifiedDividendPerShare;
  uint256 internal lastAmount;

  address public dividendToken;
  address public prismaToken;

  IUniswapV2Router02 public uniswapV2Router;
  IPrismaToken public prisma;

  /**
   * @dev About dividendCorrection:
   * If the token balance of a `_user` is never changed, the dividend of `_user` can be computed with:
   *   `dividendOf(_user) = dividendPerShare * balanceOf(_user)`.
   * When `balanceOf(_user)` is changed (via minting/burning/transferring tokens),
   *   `dividendOf(_user)` should not be changed,
   *   but the computed value of `dividendPerShare * balanceOf(_user)` is changed.
   * To keep the `dividendOf(_user)` unchanged, we add a correction term:
   *   `dividendOf(_user) = dividendPerShare * balanceOf(_user) + dividendCorrectionOf(_user)`,
   *   where `dividendCorrectionOf(_user)` is updated whenever `balanceOf(_user)` is changed:
   *   `dividendCorrectionOf(_user) = dividendPerShare * (old balanceOf(_user)) - (new balanceOf(_user))`.
   * So now `dividendOf(_user)` returns the same value before and after `balanceOf(_user)` is changed.
   */
  mapping(address => int256) internal magnifiedDividendCorrections;
  mapping(address => bool) private compoundPrisma;
  mapping(address => uint256) internal withdrawnDividends;

  uint256 public totalDividendsDistributed;

  event DividendReinvested(address indexed to, uint256 weiAmount);

  /**
   * @notice Distributes ether to token holders as dividends.
   * @dev It reverts if the total supply of tokens is 0.
   * It emits the `DividendsDistributed` event if the amount of received ether is greater than 0.
   * About undistributed ether:
   *   In each distribution, there is a small amount of ether not distributed,
   *     the magnified amount of which is
   *     `(msg.value * magnitude) % totalSupply()`.
   *   With a well-chosen `magnitude`, the amount of undistributed ether
   *     (de-magnified) in a distribution can be less than 1 wei.
   *   We can actually keep track of the undistributed ether in a distribution
   *     and try to distribute it in the next distribution,
   *     but keeping track of such data on-chain costs much more than
   *     the saved ether, so we don't do that.
   */
  function distributeDividends(uint256 amount) public virtual onlyOwner {
    require(totalSupply() > 0);

    if (amount > 0) {
      magnifiedDividendPerShare =
        magnifiedDividendPerShare +
        (amount * magnitude) /
        totalSupply();

      emit DividendsDistributed(msg.sender, amount);

      totalDividendsDistributed = totalDividendsDistributed + amount;
    }
  }

  /**
   * @notice Withdraws the ether distributed to the sender.
   * @dev It emits a `DividendWithdrawn` event if the amount of withdrawn ether is greater than 0.
   */
  function withdrawDividend() public virtual override {
    _withdrawDividendOfUser(payable(msg.sender));
  }

  function _withdrawDividendOfUser(
    address payable user
  ) internal returns (uint256) {
    uint256 _withdrawableDividend = withdrawableDividendOf(user);

    if (_withdrawableDividend > 0) {
      withdrawnDividends[user] =
        withdrawnDividends[user] +
        _withdrawableDividend;

      uint256 _netWithdrawableDividend = reinvest(user, _withdrawableDividend);

      if (_netWithdrawableDividend > 0) {
        // either some amount is reinvested or nothing is reinvested
        bool success = IERC20Upgradeable(dividendToken).transfer(
          user,
          _netWithdrawableDividend
        );

        if (!success) {
          // if claim fails, we only dedcut the `_netWithdrawableDividend` amount in total `withdrawnDividends`. Because rest amount is already invested when we called `reinvest` function above.
          withdrawnDividends[user] =
            withdrawnDividends[user] -
            _netWithdrawableDividend;
          return 0;
        }
        emit DividendReinvested(
          user,
          _withdrawableDividend - _netWithdrawableDividend
        );
        emit DividendWithdrawn(user, _netWithdrawableDividend);
      } else {
        // all amount is reinvested
        emit DividendReinvested(user, _withdrawableDividend);
        emit DividendWithdrawn(user, 0);
      }

      return _withdrawableDividend;
    }

    return 0;
  }

  /**
   * @notice Sets the address for the token used for dividend payout
   * @dev This should be an ERC20 token
   */
  function setDividendTokenAddress(
    address newToken
  ) external virtual onlyOwner {
    dividendToken = newToken;
  }

  /**
   * @notice View the amount of dividend in wei that an address can withdraw.
   * @param _owner The address of a token holder.
   * @return The amount of dividend in wei that `_owner` can withdraw.
   */
  function dividendOf(address _owner) public view override returns (uint256) {
    return withdrawableDividendOf(_owner);
  }

  /**
   * @notice View the amount of dividend in wei that an address can withdraw.
   * @param _owner The address of a token holder.
   * @return The amount of dividend in wei that `_owner` can withdraw.
   */
  function withdrawableDividendOf(
    address _owner
  ) public view virtual override returns (uint256) {
    return accumulativeDividendOf(_owner) - withdrawnDividends[_owner];
  }

  /**
   * @notice View the amount of dividend in wei that an address has withdrawn.
   * @param _owner The address of a token holder.
   * @return The amount of dividend in wei that `_owner` has withdrawn.
   */
  function withdrawnDividendOf(
    address _owner
  ) public view override returns (uint256) {
    return withdrawnDividends[_owner];
  }

  /**
   * @notice View the amount of dividend in wei that an address has earned in total.
   * @dev accumulativeDividendOf(_owner) = withdrawableDividendOf(_owner) + withdrawnDividendOf(_owner)
   * = (magnifiedDividendPerShare * balanceOf(_owner) + magnifiedDividendCorrections[_owner]) / magnitude
   * @param _owner The address of a token holder.
   * @return The amount of dividend in wei that `_owner` has earned in total.
   */
  function accumulativeDividendOf(
    address _owner
  ) public view override returns (uint256) {
    return
      uint(
        int(magnifiedDividendPerShare * balanceOf(_owner)) +
          magnifiedDividendCorrections[_owner]
      ) / magnitude;
  }

  /**
   * @dev Internal function that transfer tokens from one address to another.
   * Update magnifiedDividendCorrections to keep dividends unchanged.
   * @param from The address to transfer from.
   * @param to The address to transfer to.
   * @param value The amount to be transferred.
   */
  function _transfer(
    address from,
    address to,
    uint256 value
  ) internal virtual override {
    require(false); // currently disabled
    super._transfer(from, to, value);

    int256 _magCorrection = int(magnifiedDividendPerShare * value);
    magnifiedDividendCorrections[from] =
      magnifiedDividendCorrections[from] +
      _magCorrection;
    magnifiedDividendCorrections[to] =
      magnifiedDividendCorrections[to] -
      _magCorrection;
  }

  /**
   * @dev Internal function that mints tokens to an account.
   * Update magnifiedDividendCorrections to keep dividends unchanged.
   * @param account The account that will receive the created tokens.
   * @param value The amount that will be created.
   */
  function _mint(address account, uint256 value) internal override {
    super._mint(account, value);

    magnifiedDividendCorrections[account] =
      magnifiedDividendCorrections[account] -
      int(magnifiedDividendPerShare * value);
  }

  /**
   * @dev Internal function that burns an amount of the token of a given account.
   * Update magnifiedDividendCorrections to keep dividends unchanged.
   * @param account The account whose tokens will be burnt.
   * @param value The amount that will be burnt.
   */
  function _burn(address account, uint256 value) internal override {
    super._burn(account, value);

    magnifiedDividendCorrections[account] =
      magnifiedDividendCorrections[account] +
      int(magnifiedDividendPerShare * value);
  }

  /**
   * @notice Sets the balance of a user and adjusts supply accordingly
   * @dev Used in the `DividendTracker` contract
   */
  function _setBalance(address account, uint256 newBalance) internal {
    uint256 currentBalance = balanceOf(account);

    if (newBalance > currentBalance) {
      uint256 mintAmount = newBalance - currentBalance;
      _mint(account, mintAmount);
    } else if (newBalance < currentBalance) {
      uint256 burnAmount = currentBalance - newBalance;
      _burn(account, burnAmount);
    }
  }

  /**
   * @dev This function should be called from the d-app
   */
  function reinvest(
    address _user,
    uint256 _withdrawableDividend
  ) internal returns (uint256) {
    uint256 stakedPrisma = prisma.getStakedPrisma(_user);
    uint256 reinvestAmount;
    if (stakedPrisma > 0) {
      uint256 prismaBalance = this.balanceOf(_user);
      reinvestAmount =
        (_withdrawableDividend * ((stakedPrisma * magnitude) / prismaBalance)) /
        magnitude;
      IERC20Upgradeable(dividendToken).approve(
        address(uniswapV2Router),
        reinvestAmount
      );
      address[] memory path = new address[](2);
      path[0] = dividendToken;
      path[1] = prismaToken;
      uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
        reinvestAmount,
        0,
        path,
        _user,
        block.timestamp
      );
    }
    return _withdrawableDividend - reinvestAmount;
  }
}
