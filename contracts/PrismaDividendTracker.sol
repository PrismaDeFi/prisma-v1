// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

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
  uint256 internal constant magnitude = 2 ** 128;

  uint256 private _magnifiedPrismaPerShare;
  uint256 public magnifiedDividendPerShare;
  uint256 public lastProcessedIndex;
  uint256 public claimWait;
  uint256 public minimumTokenBalanceForDividends;
  uint256 public totalDividendsDistributed;
  uint256 private _unProcessedPrismaBalance;
  bool public _processingAutoReinvest;

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
  mapping(address => uint256) internal withdrawnDividends;
  mapping(address => bool) public excludedFromDividends;
  mapping(address => uint256) public lastClaimTimes;

  IPrismaToken public prisma;
  IUniswapV2Router02 public router;
  address public pair;
  address public dividendToken;

  ////////////
  // Events //
  ////////////

  event DividendsDistributed(address indexed from, uint256 weiAmount);
  event DividendWithdrawn(address indexed to, uint256 weiAmount);
  event ExcludeFromDividends(address indexed account);
  event DividendReinvested(address indexed to, uint256 weiAmount);
  event ClaimWaitUpdated(uint256 indexed newValue, uint256 indexed oldValue);
  event Claim(address indexed account, uint256 amount, bool indexed automatic);

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

    claimWait = 60;
    minimumTokenBalanceForDividends = 1000 * (10 ** 18);
  }

  //////////////////////////
  // Dividends Processing //
  //////////////////////////

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
  function distributeDividends(
    uint256 amount,
    bool _processAutoReinvest
  ) public onlyOwner {
    require(totalSupply() > 0);

    if (amount > 0) {
      magnifiedDividendPerShare =
        magnifiedDividendPerShare +
        (amount * magnitude) /
        totalSupply();

      emit DividendsDistributed(msg.sender, amount);

      totalDividendsDistributed = totalDividendsDistributed + amount;

      if (_processAutoReinvest) {
        reinvestV2();
      }
    }
  }

  /**
   * @notice Withdraws the ether distributed to the sender.
   * @dev It emits a `DividendWithdrawn` event if the amount of withdrawn ether is greater than 0.
   */
  function withdrawDividend() public {
    _withdrawDividendOfUser(msg.sender);
  }

  function _withdrawDividendOfUser(address user) internal returns (uint256) {
    uint256 _withdrawableDividend = withdrawableDividendOf(user);

    if (_withdrawableDividend > 0) {
      withdrawnDividends[user] =
        withdrawnDividends[user] +
        _withdrawableDividend;
      // uint256 _netWithdrawableDividend = reinvest(user, _withdrawableDividend);

      // if (_netWithdrawableDividend > 0) {
      // either some amount is reinvested or nothing is reinvested
      bool success = IERC20Upgradeable(dividendToken).transfer(
        user,
        _withdrawableDividend
      );

      if (!success) {
        // if claim fails, we only dedcut the `_netWithdrawableDividend` amount in total `withdrawnDividends`. Because rest amount is already invested when we called `reinvest` function above.
        withdrawnDividends[user] =
          withdrawnDividends[user] -
          _withdrawableDividend;
        return 0;
      }
      // emit DividendReinvested(
      //   user,
      //   _withdrawableDividend - _netWithdrawableDividend
      // );
      emit DividendWithdrawn(user, _withdrawableDividend);
      // } else {
      //   // all amount is reinvested
      //   emit DividendReinvested(user, _withdrawableDividend);
      //   emit DividendWithdrawn(user, 0);
      // }

      return _withdrawableDividend;
    }

    return 0;
  }

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
  // function reinvest(
  //   address _user,
  //   uint256 _withdrawableDividend
  // ) internal returns (uint256) {
  //   uint256 stakedPrisma = prisma.getStakedPrisma(_user);
  //   uint256 reinvestAmount;
  //   if (stakedPrisma > 0) {
  //     uint256 prismaBalance = this.balanceOf(_user);
  //     reinvestAmount =
  //       (_withdrawableDividend * ((stakedPrisma * magnitude) / prismaBalance)) /
  //       magnitude;
  //     IERC20Upgradeable(dividendToken).approve(address(router), reinvestAmount);
  //     address[] memory path = new address[](2);
  //     path[0] = dividendToken;
  //     path[1] = address(prisma);
  //     router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
  //       reinvestAmount,
  //       0,
  //       path,
  //       _user,
  //       block.timestamp
  //     );
  //   }
  //   return _withdrawableDividend - reinvestAmount;
  // }

  /**
   * @notice Used to check if an account is ready to claim
   * @return bool is ready to claim
   */
  function canAutoClaim(uint256 lastClaimTime) public view returns (bool) {
    if (lastClaimTime > block.timestamp) {
      return false;
    }

    return block.timestamp - lastClaimTime >= claimWait;
  }

  /**
   * @notice Sets the dividend balance of an account and processes its dividends
   * @dev Calls the `processAccount` function
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

    // processAccount(account, true);
  }

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
        uint256 _prismaToCompound = distributeEarnedPrisma(account);
        prisma.compoundPrisma(account, _prismaToCompound);
        claims++;
      } else if (canAutoClaim(lastClaimTimes[account])) {
        if (processAccount(account, true)) {
          claims++;
        }
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
    bool automatic
  ) public onlyOwner returns (bool) {
    uint256 amount = _withdrawDividendOfUser(account);

    if (amount > 0) {
      lastClaimTimes[account] = block.timestamp;
      emit Claim(account, amount, automatic);
      return true;
    }

    return false;
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
   * @notice Updates the minimum wait between dividend claims
   * @dev Emits a `ClaimWaitUpdated` event
   */
  function updateClaimWait(uint256 newClaimWait) external onlyOwner {
    require(
      newClaimWait >= 3600 && newClaimWait <= 86400,
      "claimWait must be updated to between 1 and 24 hours"
    );
    require(newClaimWait != claimWait, "Cannot update claimWait to same value");
    emit ClaimWaitUpdated(newClaimWait, claimWait);
    claimWait = newClaimWait;
  }

  /**
   * @notice Sets the address for the token used for dividend payout
   * @dev This should be an ERC20 token
   */
  function setDividendTokenAddress(address newToken) external onlyOwner {
    dividendToken = newToken;
  }

  ///////////////////////
  // Getter Functions //
  /////////////////////

  /**
   * @notice Returns the wait between manual dividend claims
   * @dev Can be set `updateClaimWait`
   * @return uint256 Claim wait in seconds
   */
  function getDividendClaimWait() external view returns (uint256) {
    return claimWait;
  }

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
      uint256 totalDividends,
      uint256 lastClaimTime,
      uint256 nextClaimTime,
      uint256 secondsUntilAutoClaimAvailable
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

    lastClaimTime = lastClaimTimes[account];

    nextClaimTime = lastClaimTime > 0 ? lastClaimTime + claimWait : 0;

    secondsUntilAutoClaimAvailable = nextClaimTime > block.timestamp
      ? nextClaimTime - block.timestamp
      : 0;
  }

  /**
   * @notice Returns all available info about the dividend status of an account using its index
   * @dev Uses the functions from the `IterableMapping.sol` library
   */
  function getAccountAtIndex(
    uint256 index
  )
    public
    view
    returns (
      address,
      int256,
      int256,
      uint256,
      uint256,
      uint256,
      uint256,
      uint256
    )
  {
    if (index >= tokenHoldersMap.size()) {
      return (
        0x0000000000000000000000000000000000000000,
        -1,
        -1,
        0,
        0,
        0,
        0,
        0
      );
    }

    address account = tokenHoldersMap.getKeyAtIndex(index);

    return getAccount(account);
  }

  /**
   * @dev need to rename the function and check modifier
   */
  function reinvestV2() private {
    _processingAutoReinvest = true;
    uint256 _totalStakedPrisma = prisma.getTotalStakedAmount();
    uint256 _totalUnclaimedDividend = IERC20Upgradeable(dividendToken)
      .balanceOf(address(this));

    uint256 _reinvestAmount;
    if (_totalStakedPrisma > 10 && _totalUnclaimedDividend > 10) {
      uint256 totalPrismaBalance = totalSupply();
      _reinvestAmount =
        (_totalUnclaimedDividend *
          ((_totalStakedPrisma * magnitude) / totalPrismaBalance)) /
        magnitude;
      magnifiedDividendPerShare =
        magnifiedDividendPerShare -
        (_reinvestAmount * magnitude) /
        totalSupply();
      IERC20Upgradeable(dividendToken).approve(
        address(router),
        _reinvestAmount
      );
      address[] memory path = new address[](2);
      path[0] = dividendToken;
      path[1] = address(prisma);
      router.swapExactTokensForTokens(
        _reinvestAmount,
        0,
        path,
        address(this),
        block.timestamp
      );

      uint256 _contractPrismaBalance = prisma.balanceOf(address(this));
      _magnifiedPrismaPerShare =
        (_contractPrismaBalance * magnitude) /
        _totalStakedPrisma;

      process(5_000_000, true);

      _magnifiedPrismaPerShare = 0;

      _unProcessedPrismaBalance = prisma.balanceOf(address(this));

      _processingAutoReinvest = false;

      // emit DividendsDistributed(msg.sender, _reinvestAmount);

      // totalDividendsDistributed = totalDividendsDistributed + _reinvestAmount;
    }
  }

  function distributeEarnedPrisma(address _user) public view returns (uint256) {
    uint256 _userStakedPrisma = prisma.getStakedPrisma(_user);
    uint256 _prismaDividend = (_magnifiedPrismaPerShare * _userStakedPrisma) /
      magnitude;
    return _prismaDividend;
  }

  /**
   * @dev perform manual reinvestment
   */
  function manualReinvest() external {
    require(
      !_processingAutoReinvest,
      "Not allowed for now, try after sometime!"
    );
    uint256 _withdrawableDividend = withdrawableDividendOf(msg.sender);
    if (_withdrawableDividend > 0) {
      IERC20Upgradeable(dividendToken).approve(
        address(router),
        _withdrawableDividend
      );
      address[] memory path = new address[](2);
      path[0] = dividendToken;
      path[1] = address(prisma);
      router.swapExactTokensForTokens(
        _withdrawableDividend,
        0,
        path,
        address(this),
        block.timestamp
      );
      uint256 _userPrismaBalance = prisma.balanceOf(address(this)) -
        _unProcessedPrismaBalance;
      bool success = prisma.transfer(msg.sender, _userPrismaBalance);
      if (!success) {
        require(false, "Manual reinvestment failed");
        //we can add event to catch failed manual reinvest
      }
    }
  }
}
