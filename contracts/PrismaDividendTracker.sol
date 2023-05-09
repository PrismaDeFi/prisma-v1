// ██████╗ ██████╗ ██╗███████╗███╗   ███╗ █████╗     ███████╗██╗███╗   ██╗ █████╗ ███╗   ██╗ ██████╗███████╗
// ██╔══██╗██╔══██╗██║██╔════╝████╗ ████║██╔══██╗    ██╔════╝██║████╗  ██║██╔══██╗████╗  ██║██╔════╝██╔════╝
// ██████╔╝██████╔╝██║███████╗██╔████╔██║███████║    █████╗  ██║██╔██╗ ██║███████║██╔██╗ ██║██║     █████╗
// ██╔═══╝ ██╔══██╗██║╚════██║██║╚██╔╝██║██╔══██║    ██╔══╝  ██║██║╚██╗██║██╔══██║██║╚██╗██║██║     ██╔══╝
// ██║     ██║  ██║██║███████║██║ ╚═╝ ██║██║  ██║    ██║     ██║██║ ╚████║██║  ██║██║ ╚████║╚██████╗███████╗
// ╚═╝     ╚═╝  ╚═╝╚═╝╚══════╝╚═╝     ╚═╝╚═╝  ╚═╝    ╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝╚══════╝

// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "./IPrismaDividendTracker.sol";
import "./IterableMapping.sol";
import "./IPrismaToken.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract BETA_PrismaDividendTracker is
  IPrismaDividendTracker,
  ERC20Upgradeable,
  OwnableUpgradeable
{
  using IterableMapping for IterableMapping.Map;

  IterableMapping.Map private _tokenHoldersMap;

  /////////////////
  /// CONSTANTS ///
  /////////////////

  /**
   * @dev With `magnitude`, we can properly distribute dividends even if the received amount is small.
   */
  uint256 private constant _magnitude = 2 ** 128;

  /////////////////
  /// VARIABLES ///
  /////////////////

  uint256 private _magnifiedPrismaPerShare;
  uint256 private _magnifiedDividendPerShare;
  uint256 private _lastDistribution;
  uint256 private _lastProcessedIndex;
  uint256 private _minimumTokenBalanceForDividends;
  uint256 private _gasForProcessing;
  uint256 private _totalDividendsDistributed;

  bool private _processingAutoReinvest;

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
  mapping(address => int256) private _magnifiedDividendCorrections;
  mapping(address => uint256) private _withdrawnDividends;
  mapping(address => bool) private _excludedFromDividends;

  IPrismaToken private _prisma;
  IUniswapV2Router02 private _router;

  address private _dividendToken;

  ///////////////////
  /// INITIALIZER ///
  ///////////////////

  /**
   * @notice Creates an ERC20 token that will be used to track dividends
   * @dev Sets minimum balance to be eligible
   */
  function init(
    address dividendToken_,
    address router_,
    address prisma_
  ) public initializer {
    __Ownable_init();
    __ERC20_init("Prisma Tracker", "PRISMA_TRACKER");
    _dividendToken = dividendToken_;
    _prisma = IPrismaToken(prisma_);
    _router = IUniswapV2Router02(router_);

    _minimumTokenBalanceForDividends = 1_000 * (10 ** 18);
    _gasForProcessing = 2_000_000;
  }

  /////////////
  /// ERC20 ///
  /////////////

  function balanceOf(
    address account
  )
    public
    view
    override(ERC20Upgradeable, IPrismaDividendTracker)
    returns (uint256)
  {
    return super.balanceOf(account);
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

    int256 _magCorrection = int(_magnifiedDividendPerShare * value);
    _magnifiedDividendCorrections[from] =
      _magnifiedDividendCorrections[from] +
      _magCorrection;
    _magnifiedDividendCorrections[to] =
      _magnifiedDividendCorrections[to] -
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

    _magnifiedDividendCorrections[account] =
      _magnifiedDividendCorrections[account] -
      int(_magnifiedDividendPerShare * value);
  }

  /**
   * @dev Internal function that burns an amount of the token of a given account.
   * Update magnifiedDividendCorrections to keep dividends unchanged.
   * @param account The account whose tokens will be burnt.
   * @param value The amount that will be burnt.
   */
  function _burn(address account, uint256 value) internal override {
    super._burn(account, value);

    _magnifiedDividendCorrections[account] =
      _magnifiedDividendCorrections[account] +
      int(_magnifiedDividendPerShare * value);
  }

  /**
   * @dev Since Uniswap does not allow setting the recipient of a swap as one of the tokens
   * being swapped, it is impossible to collect the swapped fees directly in the main contract.
   */

  function swapFees() external onlyOwner {
    uint256 balanceBefore = ERC20Upgradeable(_dividendToken).balanceOf(
      address(this)
    );

    uint256 balance = ERC20Upgradeable(address(_prisma)).balanceOf(
      address(this)
    );
    uint256 liquidityPrisma = (_prisma.getSellLiquidityFee() * balance) / 100;
    uint256 swapAmount = balance - liquidityPrisma;

    ERC20Upgradeable(address(_prisma)).approve(address(_router), swapAmount);
    address[] memory path = new address[](2);
    path[0] = address(_prisma);
    path[1] = _dividendToken;
    _router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
      swapAmount,
      0,
      path,
      address(this),
      block.timestamp
    );
    uint256 balanceAfter = ERC20Upgradeable(_dividendToken).balanceOf(
      address(this)
    );
    uint256 collectedFees = balanceAfter - balanceBefore;

    uint256 liquidityFee = (collectedFees * (_prisma.getSellLiquidityFee())) /
      (_prisma.getTotalSellFees());
    if (liquidityFee > 5) {
      ERC20Upgradeable(address(_prisma)).approve(
        address(_router),
        liquidityPrisma
      );
      ERC20Upgradeable(address(_dividendToken)).approve(
        address(_router),
        liquidityFee
      );
      (, uint256 amountB, ) = _router.addLiquidity(
        address(_prisma),
        _dividendToken,
        liquidityPrisma,
        liquidityFee,
        0,
        0,
        msg.sender,
        block.timestamp
      );
      collectedFees -= amountB;
    }

    uint256 treasuryFee = (collectedFees * (_prisma.getSellTreasuryFee())) /
      (_prisma.getTotalSellFees());
    ERC20Upgradeable(_dividendToken).transfer(
      _prisma.getTreasuryReceiver(),
      treasuryFee
    );
    collectedFees -= treasuryFee;

    uint256 itfFee = collectedFees;
    ERC20Upgradeable(_dividendToken).transfer(_prisma.getItfReceiver(), itfFee);
  }

  //////////////////////////////
  /// Dividends Distribution ///
  //////////////////////////////

  /**
   * @notice Updates the holders struct
   */
  function setBalance(address account, uint256 newBalance) external onlyOwner {
    if (_excludedFromDividends[account]) {
      return;
    }

    if (newBalance >= _minimumTokenBalanceForDividends) {
      _setBalance(account, newBalance);
      _tokenHoldersMap.set(account, newBalance);
    } else {
      _setBalance(account, 0);
      _tokenHoldersMap.remove(account);
    }
  }

  /**
   * @notice Sets the balance of a user and adjusts supply accordingly
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
   * @notice Distributes stablecoins to token holders as dividends.
   * @dev It reverts if the total supply of tokens is 0.
   * About undistributed stablecoins:
   *   In each distribution, there is a small amount of stablecoins not distributed,
   *     the magnified amount of which is
   *     `(amount * magnitude) % totalSupply()`.
   *   With a well-chosen `magnitude`, the amount of undistributed stablecoins
   *     (de-magnified) in a distribution can be less than 1 wei.
   *   We can actually keep track of the undistributed stablecoins in a distribution
   *     and try to distribute it in the next distribution,
   *     but keeping track of such data on-chain costs much more than
   *     the saved stablecoins, so we don't do that.
   */
  function distributeDividends(bool processDividends) external {
    require(msg.sender == _prisma.getOwner(), "Not owner.");
    require(totalSupply() > 0);

    uint256 amount = ERC20Upgradeable(_dividendToken).balanceOf(address(this)) -
      _lastDistribution;
    if (amount > 0) {
      _magnifiedDividendPerShare += (amount * _magnitude) / totalSupply();

      _totalDividendsDistributed += amount;

      if (processDividends) {
        process(_gasForProcessing, false);
        autoReinvest();
      }

      _lastDistribution = ERC20Upgradeable(_dividendToken).balanceOf(
        address(this)
      );
    }
  }

  ////////////////////////////
  /// Dividends Withdrawal ///
  ////////////////////////////

  /**
   * @notice Processes dividends for all token holders
   * @param gas Amount of gas to use for the transaction
   */
  function process(
    uint256 gas,
    bool reinvesting
  ) internal returns (uint256, uint256, uint256) {
    uint256 numberOfTokenHolders = _tokenHoldersMap.keys.length;

    if (numberOfTokenHolders == 0) {
      return (0, 0, _lastProcessedIndex);
    }

    uint256 lastProcessedIndex = _lastProcessedIndex;

    uint256 gasUsed = 0;

    uint256 gasLeft = gasleft();

    uint256 iterations = 0;
    uint256 claims = 0;

    while (gasUsed < gas && iterations < numberOfTokenHolders) {
      lastProcessedIndex++;

      if (lastProcessedIndex >= _tokenHoldersMap.keys.length) {
        lastProcessedIndex = 0;
      }

      address account = _tokenHoldersMap.keys[lastProcessedIndex];

      if (reinvesting) {
        if (processReinvest(account)) {
          claims++;
        }
      } else if (processAccount(account, 0)) {
        claims++;
      }

      iterations++;

      uint256 newGasLeft = gasleft();

      if (gasLeft > newGasLeft) {
        gasUsed = gasUsed + gasLeft - newGasLeft;
      }

      gasLeft = newGasLeft;
    }

    _lastProcessedIndex = lastProcessedIndex;

    return (iterations, claims, _lastProcessedIndex);
  }

  /**
   * @notice Processes dividends for an account
   * @return bool success
   */
  function processAccount(
    address account,
    uint256 amount
  ) internal returns (bool) {
    uint256 _amount;
    if (amount == 0) {
      uint256 _withdrawableDividend = withdrawableDividendOf(account) -
        (withdrawableDividendOf(account) *
          ((_prisma.getStakedPrisma(account) * _magnitude) /
            balanceOf(account))) /
        _magnitude;
      _amount = _withdrawDividendOfUser(account, _withdrawableDividend);
    } else {
      _amount = _withdrawDividendOfUser(account, amount);
    }

    if (_amount > 0) {
      return true;
    }

    return false;
  }

  /**
   * @notice Allows a user to manually withdraw their own dividends
   * @return bool success
   */

  function claim(uint256 amount) external returns (bool) {
    address account = msg.sender;
    uint256 _amount;
    if (amount == 0) {
      uint256 _withdrawableDividend = withdrawableDividendOf(account) -
        (withdrawableDividendOf(account) *
          ((_prisma.getStakedPrisma(account) * _magnitude) /
            balanceOf(account))) /
        _magnitude;
      _amount = _withdrawDividendOfUser(account, _withdrawableDividend);
    } else {
      _amount = _withdrawDividendOfUser(account, amount);
    }

    if (_amount > 0) {
      _lastDistribution -= _amount;
      return true;
    }

    return false;
  }

  /**
   * @notice Withdraws the stablecoins distributed to the sender.
   */

  function _withdrawDividendOfUser(
    address user,
    uint256 amount
  ) internal returns (uint256) {
    uint256 _withdrawableDividend = withdrawableDividendOf(user);

    if (_withdrawableDividend > 0 && amount <= _withdrawableDividend) {
      _withdrawnDividends[user] += amount;

      bool success = IERC20Upgradeable(_dividendToken).transfer(user, amount);

      if (!success) {
        _withdrawnDividends[user] = _withdrawnDividends[user] - amount;
        return 0;
      }

      return amount;
    }

    return 0;
  }

  ///////////////////////////////
  /// Dividends Reinvestmnent ///
  ///////////////////////////////

  /**
   * @dev Internal function used to reinvest and compound all the dividends of Prisma stakers
   */

  function autoReinvest() internal {
    uint256 _totalStakedPrisma = _prisma.getTotalStakedAmount();
    uint256 _totalUnclaimedDividend = IERC20Upgradeable(_dividendToken)
      .balanceOf(address(this));
    if (_totalStakedPrisma > 10 && _totalUnclaimedDividend > 10) {
      _processingAutoReinvest = true;
      IERC20Upgradeable(_dividendToken).approve(
        address(_router),
        _totalUnclaimedDividend
      );
      address[] memory path = new address[](2);
      path[0] = _dividendToken;
      path[1] = address(_prisma);
      _router.swapExactTokensForTokens(
        _totalUnclaimedDividend,
        0,
        path,
        address(this),
        block.timestamp
      );

      uint256 _contractPrismaBalance = ERC20Upgradeable(address(_prisma))
        .balanceOf(address(this));
      _magnifiedPrismaPerShare =
        (_contractPrismaBalance * _magnitude) /
        _totalStakedPrisma;

      process(_gasForProcessing, true);

      _magnifiedPrismaPerShare = 0;

      _processingAutoReinvest = false;

      _totalDividendsDistributed += _totalUnclaimedDividend;
    }
  }

  /**
   * @dev Internal function used to compound Prisma for `_user`
   */
  function processReinvest(address _user) internal returns (bool) {
    uint256 _reinvestableDividend = withdrawableDividendOf(_user);

    if (_reinvestableDividend > 0) {
      _withdrawnDividends[_user] += _reinvestableDividend;
      uint256 _prismaToCompound = distributeEarnedPrisma(_user);
      _prisma.compoundPrisma(_user, _prismaToCompound);
      return true;
    }
    return false;
  }

  /**
   * @notice Allows users to manually reinvest an arbitrary amount of dividends
   */
  function manualReinvest(uint256 amount) external {
    require(!_processingAutoReinvest, "Not allowed now, retry later.");
    uint256 _withdrawableDividend = withdrawableDividendOf(msg.sender);
    if (_withdrawableDividend > 0 && amount <= _withdrawableDividend) {
      uint256 balanceBefore = ERC20Upgradeable(address(_prisma)).balanceOf(
        address(this)
      );

      _withdrawnDividends[msg.sender] += amount;
      _lastDistribution -= amount;
      IERC20Upgradeable(_dividendToken).approve(address(_router), amount);
      address[] memory path = new address[](2);
      path[0] = _dividendToken;
      path[1] = address(_prisma);
      _router.swapExactTokensForTokens(
        amount,
        0,
        path,
        address(this),
        block.timestamp
      );
      uint256 balanceAfter = ERC20Upgradeable(address(_prisma)).balanceOf(
        address(this)
      );

      uint256 _userPrisma = balanceAfter - balanceBefore;
      _prisma.compoundPrisma(msg.sender, _userPrisma);
    }
  }

  //////////////////////
  /// Dividends Math ///
  //////////////////////

  /**
   * @notice View the amount of dividend in wei that an address can withdraw.
   * @param _owner The address of a token holder.
   * @return The amount of dividend in wei that `_owner` can withdraw.
   */
  function withdrawableDividendOf(
    address _owner
  ) public view returns (uint256) {
    return accumulativeDividendOf(_owner) - _withdrawnDividends[_owner];
  }

  /**
   * @notice View the amount of dividend in wei that an address has withdrawn.
   * @param _owner The address of a token holder.
   * @return The amount of dividend in wei that `_owner` has withdrawn.
   */
  function withdrawnDividendOf(address _owner) public view returns (uint256) {
    return _withdrawnDividends[_owner];
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
  ) public view returns (uint256) {
    return
      uint(
        int(_magnifiedDividendPerShare * balanceOf(_owner)) +
          _magnifiedDividendCorrections[_owner]
      ) / _magnitude;
  }

  /**
   * @notice View the amount of Prisma an address has earned from staking
   */
  function distributeEarnedPrisma(address _user) public view returns (uint256) {
    uint256 _userStakedPrisma = _prisma.getStakedPrisma(_user);
    uint256 _prismaDividend = (_magnifiedPrismaPerShare * _userStakedPrisma) /
      _magnitude;
    return _prismaDividend;
  }

  ////////////////////////
  /// Setter Functions ///
  ////////////////////////

  /**
   * @notice Updates the minimum balance required to be eligible for dividends
   */
  function updateMinimumTokenBalanceForDividends(
    uint256 _newMinimumBalance
  ) external onlyOwner {
    require(
      _newMinimumBalance != _minimumTokenBalanceForDividends,
      "New mimimum balance for dividend cannot be same as current minimum balance."
    );
    _minimumTokenBalanceForDividends = _newMinimumBalance * (10 ** 18);
  }

  /**
   * @notice Makes an address ineligible for dividends
   * @dev Calls `_setBalance` and updates `tokenHoldersMap` iterable mapping
   */
  function excludeFromDividends(address account) external onlyOwner {
    require(
      !_excludedFromDividends[account],
      "Address already excluded from dividends."
    );
    _excludedFromDividends[account] = true;

    _setBalance(account, 0);
    _tokenHoldersMap.remove(account);
  }

  /**
   * @notice Makes an address eligible for dividends
   */
  function includeFromDividends(address account) external onlyOwner {
    _excludedFromDividends[account] = false;
  }

  /**
   * @notice Sets the address for the token used for dividend payout
   * @dev This should be an ERC20 token
   */
  function setDividendTokenAddress(address newToken) external onlyOwner {
    _dividendToken = newToken;
  }

  /**
   * @dev Updates the amount of gas used to process dividends
   */
  function updateGasForProcessing(uint256 newValue) external onlyOwner {
    require(
      newValue != _gasForProcessing,
      "Cannot update gasForProcessing to same value."
    );
    _gasForProcessing = newValue;
  }

  ////////////////////////
  /// Getter Functions ///
  ////////////////////////

  /**
   * @notice Returns the total amount of dividends distributed by the contract
   *
   */
  function getTotalDividendsDistributed() external view returns (uint256) {
    return _totalDividendsDistributed;
  }

  /**
   * @notice Returns the last processed index in the `tokenHoldersMap` iterable mapping
   * @return uint256 last processed index
   */
  function getLastProcessedIndex() external view returns (uint256) {
    return _lastProcessedIndex;
  }

  /**
   * @notice Returns the total number of dividend token holders
   * @return uint256 length of `tokenHoldersMap` iterable mapping
   */
  function getNumberOfTokenHolders() external view returns (uint256) {
    return _tokenHoldersMap.keys.length;
  }

  /**
   * @notice Returns all available info about the dividend status of an account
   * @dev Uses the functions from the `IterableMapping.sol` library
   */
  function getAccount(
    address _account
  )
    public
    view
    returns (
      address account,
      int256 index,
      int256 iterationsUntilProcessed,
      uint256 withdrawableDividends,
      uint256 totalDividends
    )
  {
    account = _account;

    index = _tokenHoldersMap.getIndexOfKey(account);

    iterationsUntilProcessed = -1;

    if (index >= 0) {
      if (uint256(index) > _lastProcessedIndex) {
        iterationsUntilProcessed = index - int256(_lastProcessedIndex);
      } else {
        uint256 processesUntilEndOfArray = _tokenHoldersMap.keys.length >
          _lastProcessedIndex
          ? _tokenHoldersMap.keys.length - _lastProcessedIndex
          : 0;

        iterationsUntilProcessed = index + int256(processesUntilEndOfArray);
      }
    }

    withdrawableDividends = withdrawableDividendOf(account);
    totalDividends = accumulativeDividendOf(account);
  }

  /**
   * @notice Returns all available info about the dividend status of an account using its index
   * @dev Uses the functions from the `IterableMapping.sol` library
   */
  function getAccountAtIndex(
    uint256 index
  ) public view returns (address, int256, int256, uint256, uint256) {
    if (index >= _tokenHoldersMap.size()) {
      return (0x0000000000000000000000000000000000000000, -1, -1, 0, 0);
    }

    address account = _tokenHoldersMap.getKeyAtIndex(index);

    return getAccount(account);
  }

  /**
   * @notice Returns the minimum token balance required to be eligible for dividends
   */
  function getMinBalanceForDividends() external view returns (uint256) {
    return _minimumTokenBalanceForDividends;
  }
}
