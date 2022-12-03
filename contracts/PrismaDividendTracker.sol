//SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

import "./DividendPayingToken/DividendPayingToken.sol";
import "./IterableMapping/IterableMapping.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

contract PrismaDividendTracker is DividendPayingToken {
  using IterableMapping for IterableMapping.Map;

  IterableMapping.Map private tokenHoldersMap;

  mapping(address => bool) public excludedFromDividends;
  mapping(address => uint256) public lastClaimTimes;

  uint256 public lastProcessedIndex;
  uint256 public claimWait;
  uint256 public minimumTokenBalanceForDividends;

  IUniswapV2Router02 public router;
  address public pair;

  event ExcludeFromDividends(address indexed account);
  event ClaimWaitUpdated(uint256 indexed newValue, uint256 indexed oldValue);

  event Claim(address indexed account, uint256 amount, bool indexed automatic);

  /**
   * @notice Creates an ERC20 token that will be used to track dividends
   * @dev Sets minimum wait between dividend claims and minimum balance to be eligible
   */
  constructor(
    address _dividentToken,
    address _router,
    address _prisma
  )
    DividendPayingToken(
      "Prisma Tracker",
      "PRISMA_TRACKER",
      _dividentToken,
      _router,
      _prisma
    )
  {
    claimWait = 60;
    minimumTokenBalanceForDividends = 1000 * (10 ** 18);

    IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(_router);
    address _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
      .createPair(_prisma, _dividentToken);

    router = _uniswapV2Router;
    pair = _uniswapV2Pair;
  }

  /**
   * @dev See natspec in `DividendPayingToken.sol`
   */
  function setDividendTokenAddress(
    address newToken
  ) external override onlyOwner {
    dividendToken = newToken;
  }

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
   * @notice Used to check if an account is ready to claim
   * @return bool is ready to claim
   */
  function canAutoClaim(uint256 lastClaimTime) private view returns (bool) {
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
  function process(uint256 gas) public returns (uint256, uint256, uint256) {
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

      if (canAutoClaim(lastClaimTimes[account])) {
        if (processAccount(payable(account), true)) {
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
    address payable account,
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
}
