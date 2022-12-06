// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

interface IPrismaDividendTracker {
  /**
   * @notice Sets the address for the token used for dividend payout
   * @dev This should be an ERC20 token
   */
  function setDividendTokenAddress(address newToken) external;

  /**
   * @notice Updates the minimum balance required to be eligible for dividends
   */
  function updateMinimumTokenBalanceForDividends(
    uint256 _newMinimumBalance
  ) external;

  /**
   * @notice Makes an address ineligible for dividends
   * @dev Calls `_setBalance` and updates `tokenHoldersMap` iterable mapping
   */
  function excludeFromDividends(address account) external;

  /**
   * @notice Makes an address eligible for dividends
   */
  function includeFromDividends(address account) external;

  /**
   * @notice Updates the minimum wait between dividend claims
   * @dev Emits a `ClaimWaitUpdated` event
   */
  function updateClaimWait(uint256 newClaimWait) external;

  /**
   * @notice Returns the last processed index in the `tokenHoldersMap` iterable mapping
   * @return uint256 last processed index
   */
  function getLastProcessedIndex() external view returns (uint256);

  /**
   * @notice Returns the total number of dividend token holders
   * @return uint256 length of `tokenHoldersMap` iterable mapping
   */
  function getNumberOfTokenHolders() external view returns (uint256);

  /**
   * @notice Returns all available info about the dividend status of an account
   * @dev Uses the functions from the `IterableMapping.sol` library
   */
  function getAccount(
    address _account
  )
    external
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
    );

  /**
   * @notice Returns all available info about the dividend status of an account using its index
   * @dev Uses the functions from the `IterableMapping.sol` library
   */
  function getAccountAtIndex(
    uint256 index
  )
    external
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
    );

  /**
   * @notice Used to check if an account is ready to claim
   * @return bool is ready to claim
   */
  function canAutoClaim(uint256 lastClaimTime) external view returns (bool);

  /**
   * @notice Sets the dividend balance of an account and processes its dividends
   * @dev Calls the `processAccount` function
   */
  function setBalance(address payable account, uint256 newBalance) external;

  /**
   * @notice Processes dividends for all token holders
   * @param gas Amount of gas to use for the transaction
   */
  function process(
    uint256 gas,
    bool reinvesting
  ) external returns (uint256, uint256, uint256);

  /**
   * @notice Processes dividends for an account
   * @dev Emits a `Claim` event
   * @return bool success
   */
  function processAccount(
    address account,
    bool automatic
  ) external returns (bool);

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
    bool processAutoReinvest
  ) external;

  /**
   * @dev Returns the amount of tokens owned by `account`.
   */
  function balanceOf(address account) external view returns (uint256);

  /**
   * @notice Returns the wait between manual dividend claims
   * @dev Can be set `updateClaimWait`
   */
  function getDividendClaimWait() external view returns (uint256);

  /**
   * @notice Returns the total amount of dividends distributed by the contract
   *
   */
  function getTotalDividendsDistributed() external view returns (uint256);

  /**
   * @notice View the amount of dividend in wei that an address can withdraw.
   * @param _owner The address of a token holder.
   * @return The amount of dividend in wei that `_owner` can withdraw.
   */
  function withdrawableDividendOf(
    address _owner
  ) external view returns (uint256);
}
