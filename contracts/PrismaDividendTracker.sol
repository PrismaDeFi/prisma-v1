// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "./IPrismaDividendTracker.sol";
import "./IterableMapping.sol";
import "./IPrismaToken.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract PrismaDividendTracker is
  IPrismaDividendTracker,
  ERC20Upgradeable,
  OwnableUpgradeable
{
  using IterableMapping for IterableMapping.Map;

  IterableMapping.Map private tokenHoldersMap;

  ///////////////
  // VARIABLES //
  ///////////////

  /**
   * @dev With `magnitude`, we can properly distribute dividends even if the amount of received ether is small.
   */
  uint256 private constant magnitude = 2 ** 128;

  uint256 private _magnifiedPrismaPerShare;
  uint256 private magnifiedDividendPerShare;
  uint256 private lastProcessedIndex;
  uint256 private minimumTokenBalanceForDividends;
  uint256 private gasForProcessing = 10_000_000;
  uint256 private totalDividendsDistributed;
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
  mapping(address => int256) private magnifiedDividendCorrections;
  mapping(address => uint256) private withdrawnDividends;
  mapping(address => bool) private excludedFromDividends;

  IPrismaToken private prisma;
  IUniswapV2Router02 private router;
  address private pair;
  address private dividendToken;

  ////////////
  // Events //
  ////////////

  event DividendsDistributed(address indexed from, uint256 weiAmount);
  event DividendWithdrawn(address indexed to, uint256 weiAmount);
  event ExcludeFromDividends(address indexed account);
  event DividendReinvested(address indexed to, uint256 weiAmount);
  event ClaimWaitUpdated(uint256 indexed newValue, uint256 indexed oldValue);
  event Claim(address indexed account, uint256 amount, bool indexed automatic);
  event Reinvested(
    address indexed account,
    uint256 amount,
    uint256 received,
    bool indexed automatic
  );
  event GasForProcessing_Updated(
    uint256 indexed newValue,
    uint256 indexed oldValue
  );

  /////////////////
  // INITIALIZER //
  /////////////////

  /**
   * @notice Creates an ERC20 token that will be used to track dividends
   * @dev Sets minimum wait between dividend claims and minimum balance to be eligible
   */
  function init(
    address _dividentToken,
    address _router,
    address _prisma
  ) public initializer {
    __Ownable_init();
    __ERC20_init("Prisma Tracker", "PRISMA_TRACKER");
    dividendToken = _dividentToken;
    prisma = IPrismaToken(_prisma);
    router = IUniswapV2Router02(_router);
    pair = IUniswapV2Factory(router.factory()).createPair(
      _prisma,
      _dividentToken
    );

    minimumTokenBalanceForDividends = 1000 * (10 ** 18);
  }

  ///////////
  // ERC20 //
  ///////////

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
   * @dev This is only intented for test environment, since Uniswap does not allow setting
   * the recipient of a swap as one of the tokens being swapped, making it impossible to
   * collect the swapped fees directly in the main contract. However, this limitation does
   * not exist when swapping for the chain's native token, which will be our case in prod.
   */

  function swapFees() external {
    uint256 balanceBefore = ERC20Upgradeable(dividendToken).balanceOf(
      address(this)
    );

    uint256 balance = prisma.balanceOf(address(this));
    uint256 liquidityFee = (prisma.getSellLiquidityFee() * balance) / 100;
    uint256 burnFee = (prisma.getSellBurnFee() * balance) / 100;
    uint256 swapAmount = balance - liquidityFee - burnFee;

    ERC20Upgradeable(address(prisma)).approve(address(router), swapAmount);
    address[] memory path = new address[](2);
    path[0] = address(prisma);
    path[1] = dividendToken;
    router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
      swapAmount,
      0,
      path,
      address(this),
      block.timestamp
    );
    uint256 balanceAfter = ERC20Upgradeable(dividendToken).balanceOf(
      address(this)
    );
    uint256 collectedFees = balanceAfter - balanceBefore;

    if (burnFee > 0) {
      super._transfer(address(this), address(0x0), burnFee);
    }

    uint256 liquidityBNB = (collectedFees * (prisma.getSellLiquidityFee())) /
      (prisma.getTotalSellFees());
    if (liquidityBNB > 5) {
      ERC20Upgradeable(address(prisma)).approve(address(router), liquidityFee);
      ERC20Upgradeable(address(dividendToken)).approve(
        address(router),
        liquidityBNB
      );
      (, uint256 amountB, ) = router.addLiquidity(
        address(prisma),
        dividendToken,
        liquidityFee,
        liquidityBNB,
        0,
        0,
        msg.sender,
        block.timestamp
      );
      collectedFees -= amountB;
    }

    if (burnFee > 0) {
      uint256 burnBNB = (collectedFees * (prisma.getSellBurnFee())) /
        (prisma.getTotalSellFees());
      ERC20Upgradeable(dividendToken).transfer(prisma.getBurn(), burnBNB);
      // (bool success_, ) = address(burnReceiver).call{value: burnBNB}("");
      // if (success_) {
      //   emit BurnFeeCollected(burnBNB);
      // }
      collectedFees -= burnBNB;
    }

    // uint256 treasuryBNB = (collectedFees * (prisma.getSellTreasuryFee())) /
    //   (prisma.getTotalSellFees());
    uint256 treasuryBNB = collectedFees;
    ERC20Upgradeable(dividendToken).transfer(prisma.getTreasury(), treasuryBNB);
    // (bool _success, ) = address(treasuryReceiver).call{value: treasuryBNB}("");
    // if (_success) {
    //   emit TreasuryFeeCollected(treasuryBNB);
    // }
  }

  ////////////////////////////
  // Dividends Distribution //
  ////////////////////////////

  /**
   * @notice Updates the holders struct
   */
  function setBalance(
    address payable account,
    uint256 newBalance
  ) external onlyOwner {
    if (excludedFromDividends[account]) {
      return;
    }

    if (newBalance >= minimumTokenBalanceForDividends) {
      _setBalance(account, newBalance);
      tokenHoldersMap.set(account, newBalance);
    } else {
      _setBalance(account, 0);
      tokenHoldersMap.remove(account);
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
   * !!! onlyOwner modifier temporarily removed - to check whether it is needed !!!
   */
  function distributeDividends(bool processDividends) external {
    // require(msg.sender == prisma.getMultisig(), "Not multisig");
    require(totalSupply() > 0);

    uint256 amount = ERC20Upgradeable(dividendToken).balanceOf(address(this));
    if (amount > 0) {
      magnifiedDividendPerShare =
        magnifiedDividendPerShare +
        (amount * magnitude) /
        totalSupply();

      emit DividendsDistributed(msg.sender, amount);

      totalDividendsDistributed = totalDividendsDistributed + amount;

      if (processDividends) {
        process(gasForProcessing, false);
        autoReinvest();
      }
    }
  }

  //////////////////////////
  // Dividends Withdrawal //
  //////////////////////////

  /**
   * @notice Processes dividends for all token holders
   * @param gas Amount of gas to use for the transaction
   */
  function process(
    uint256 gas,
    bool reinvesting
  ) public returns (uint256, uint256, uint256) {
    uint256 numberOfTokenHolders = tokenHoldersMap.keys.length;

    if (numberOfTokenHolders == 0) {
      return (0, 0, lastProcessedIndex);
    }

    uint256 _lastProcessedIndex = lastProcessedIndex;

    uint256 gasUsed = 0;

    uint256 gasLeft = gasleft();

    uint256 iterations = 0;
    uint256 claims = 0;

    while (gasUsed < gas && iterations < numberOfTokenHolders) {
      _lastProcessedIndex++;

      if (_lastProcessedIndex >= tokenHoldersMap.keys.length) {
        _lastProcessedIndex = 0;
      }

      address account = tokenHoldersMap.keys[_lastProcessedIndex];

      if (reinvesting) {
        if (processReinvest(account, true)) {
          claims++;
        }
      } else if (processAccount(account, true, 0)) {
        claims++;
      }

      iterations++;

      uint256 newGasLeft = gasleft();

      if (gasLeft > newGasLeft) {
        gasUsed = gasUsed + gasLeft - newGasLeft;
      }

      gasLeft = newGasLeft;
    }

    lastProcessedIndex = _lastProcessedIndex;

    return (iterations, claims, lastProcessedIndex);
  }

  /**
   * @notice Processes dividends for an account
   * @dev Emits a `Claim` event
   * @return bool success
   */
  function processAccount(
    address account,
    bool automatic,
    uint256 amount
  ) public returns (bool) {
    uint256 _amount;
    if (amount == 0) {
      uint256 _withdrawableDividend = withdrawableDividendOf(account) -
        (withdrawableDividendOf(account) *
          ((prisma.getStakedPrisma(account) * magnitude) /
            balanceOf(account))) /
        magnitude;
      _amount = _withdrawDividendOfUser(account, _withdrawableDividend);
    } else {
      _amount = _withdrawDividendOfUser(account, amount);
    }

    if (_amount > 0) {
      emit Claim(account, _amount, automatic);
      return true;
    }

    return false;
  }

  /**
   * @notice Withdraws the ether distributed to the sender.
   * @dev It emits a `DividendWithdrawn` event if the amount of withdrawn ether is greater than 0.
   */

  function _withdrawDividendOfUser(
    address user,
    uint256 amount
  ) internal returns (uint256) {
    uint256 _withdrawableDividend = withdrawableDividendOf(user);

    if (_withdrawableDividend > 0 && amount <= _withdrawableDividend) {
      withdrawnDividends[user] += amount;

      bool success = IERC20Upgradeable(dividendToken).transfer(user, amount);

      if (!success) {
        withdrawnDividends[user] = withdrawnDividends[user] - amount;
        return 0;
      }

      emit DividendWithdrawn(user, amount);

      return amount;
    }

    return 0;
  }

  /////////////////////////////
  // Dividends Reinvestmnent //
  ////////////////////////////

  function autoReinvest() internal {
    uint256 _totalStakedPrisma = prisma.getTotalStakedAmount();
    uint256 _totalUnclaimedDividend = IERC20Upgradeable(dividendToken)
      .balanceOf(address(this));
    if (_totalStakedPrisma > 10 && _totalUnclaimedDividend > 10) {
      _processingAutoReinvest = true;
      IERC20Upgradeable(dividendToken).approve(
        address(router),
        _totalUnclaimedDividend
      );
      address[] memory path = new address[](2);
      path[0] = dividendToken;
      path[1] = address(prisma);
      router.swapExactTokensForTokens(
        _totalUnclaimedDividend,
        0,
        path,
        address(this),
        block.timestamp
      );

      uint256 _contractPrismaBalance = prisma.balanceOf(address(this));
      _magnifiedPrismaPerShare =
        (_contractPrismaBalance * magnitude) /
        _totalStakedPrisma;

      process(10_000_000, true);

      _magnifiedPrismaPerShare = 0;

      _processingAutoReinvest = false;

      // emit DividendsDistributed(msg.sender, _reinvestAmount);

      // totalDividendsDistributed = totalDividendsDistributed + _reinvestAmount;
    }
  }

  /**
   * @dev This function is used when we process auto reinvest in `_withdrawDividendOfUser`
   * It add the dividend equivalent to transfered prisma in `withdrawnDividends[user]`
   * It compound the prisma to user prisma balance
   *
   */
  function processReinvest(
    address _user,
    bool _automatic
  ) internal returns (bool) {
    uint256 _reinvestableDividend = withdrawableDividendOf(_user);

    if (_reinvestableDividend > 0) {
      withdrawnDividends[_user] += _reinvestableDividend;
      uint256 _prismaToCompound = distributeEarnedPrisma(_user);
      prisma.compoundPrisma(_user, _prismaToCompound);
      emit Reinvested(
        _user,
        _reinvestableDividend,
        _prismaToCompound,
        _automatic
      );
      return true;
    }
    return false;
  }

  /**
   * @notice Allows users to manually reinvest an arbitrary amount of dividends
   */
  function manualReinvest(uint256 amount) external {
    require(
      !_processingAutoReinvest,
      "Not allowed for now, try after sometime!"
    );
    uint256 _withdrawableDividend = withdrawableDividendOf(msg.sender);
    if (_withdrawableDividend > 0 && amount <= _withdrawableDividend) {
      uint256 balanceBefore = prisma.balanceOf(address(this));

      withdrawnDividends[msg.sender] += amount;
      IERC20Upgradeable(dividendToken).approve(address(router), amount);
      address[] memory path = new address[](2);
      path[0] = dividendToken;
      path[1] = address(prisma);
      router.swapExactTokensForTokens(
        amount,
        0,
        path,
        address(this),
        block.timestamp
      );
      uint256 balanceAfter = prisma.balanceOf(address(this));

      uint256 _userPrisma = balanceAfter - balanceBefore;
      prisma.compoundPrisma(msg.sender, _userPrisma);
    }
  }

  ////////////////////
  // Dividends Math //
  ////////////////////

  /**
   * @notice View the amount of dividend in wei that an address can withdraw.
   * @param _owner The address of a token holder.
   * @return The amount of dividend in wei that `_owner` can withdraw.
   */
  function withdrawableDividendOf(
    address _owner
  ) public view returns (uint256) {
    return accumulativeDividendOf(_owner) - withdrawnDividends[_owner];
  }

  /**
   * @notice View the amount of dividend in wei that an address has withdrawn.
   * @param _owner The address of a token holder.
   * @return The amount of dividend in wei that `_owner` has withdrawn.
   */
  function withdrawnDividendOf(address _owner) public view returns (uint256) {
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
  ) public view returns (uint256) {
    return
      uint(
        int(magnifiedDividendPerShare * balanceOf(_owner)) +
          magnifiedDividendCorrections[_owner]
      ) / magnitude;
  }

  function distributeEarnedPrisma(address _user) public view returns (uint256) {
    uint256 _userStakedPrisma = prisma.getStakedPrisma(_user);
    uint256 _prismaDividend = (_magnifiedPrismaPerShare * _userStakedPrisma) /
      magnitude;
    return _prismaDividend;
  }

  //////////////////////
  // Setter Functions //
  //////////////////////

  /**
   * @notice Updates the minimum balance required to be eligible for dividends
   */
  function updateMinimumTokenBalanceForDividends(
    uint256 _newMinimumBalance
  ) external onlyOwner {
    require(
      _newMinimumBalance != minimumTokenBalanceForDividends,
      "New mimimum balance for dividend cannot be same as current minimum balance"
    );
    minimumTokenBalanceForDividends = _newMinimumBalance * (10 ** 18);
  }

  /**
   * @notice Makes an address ineligible for dividends
   * @dev Calls `_setBalance` and updates `tokenHoldersMap` iterable mapping
   */
  function excludeFromDividends(address account) external onlyOwner {
    require(
      !excludedFromDividends[account],
      "address already excluded from dividends"
    );
    excludedFromDividends[account] = true;

    _setBalance(account, 0);
    tokenHoldersMap.remove(account);

    emit ExcludeFromDividends(account);
  }

  /**
   * @notice Makes an address eligible for dividends
   */
  function includeFromDividends(address account) external onlyOwner {
    excludedFromDividends[account] = false;
  }

  /**
   * @notice Sets the address for the token used for dividend payout
   * @dev This should be an ERC20 token
   */
  function setDividendTokenAddress(address newToken) external onlyOwner {
    dividendToken = newToken;
  }

  function updateGasForProcessing(uint256 newValue) external onlyOwner {
    require(
      newValue != gasForProcessing,
      "Cannot update gasForProcessing to same value"
    );
    gasForProcessing = newValue;
    emit GasForProcessing_Updated(newValue, gasForProcessing);
  }

  ///////////////////////
  // Getter Functions //
  /////////////////////

  /**
   * @notice Returns the total amount of dividends distributed by the contract
   *
   */
  function getTotalDividendsDistributed() external view returns (uint256) {
    return totalDividendsDistributed;
  }

  /**
   * @notice Returns the last processed index in the `tokenHoldersMap` iterable mapping
   * @return uint256 last processed index
   */
  function getLastProcessedIndex() external view returns (uint256) {
    return lastProcessedIndex;
  }

  /**
   * @notice Returns the total number of dividend token holders
   * @return uint256 length of `tokenHoldersMap` iterable mapping
   */
  function getNumberOfTokenHolders() external view returns (uint256) {
    return tokenHoldersMap.keys.length;
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

    index = tokenHoldersMap.getIndexOfKey(account);

    iterationsUntilProcessed = -1;

    if (index >= 0) {
      if (uint256(index) > lastProcessedIndex) {
        iterationsUntilProcessed = index - int256(lastProcessedIndex);
      } else {
        uint256 processesUntilEndOfArray = tokenHoldersMap.keys.length >
          lastProcessedIndex
          ? tokenHoldersMap.keys.length - lastProcessedIndex
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
    if (index >= tokenHoldersMap.size()) {
      return (0x0000000000000000000000000000000000000000, -1, -1, 0, 0);
    }

    address account = tokenHoldersMap.getKeyAtIndex(index);

    return getAccount(account);
  }
}
