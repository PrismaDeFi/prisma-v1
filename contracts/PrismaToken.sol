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
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./IPrismaToken.sol";
import "./IPrismaDividendTracker.sol";

contract BETA_PrismaToken is
  IPrismaToken,
  ERC20Upgradeable,
  OwnableUpgradeable
{
  /////////////////
  /// CONSTANTS ///
  /////////////////

  /**
   * @notice Dead wallet used for token burns.
   */

  address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

  /////////////////
  /// VARIABLES ///
  /////////////////

  IPrismaDividendTracker private _prismaDividendTracker;

  address private _treasuryReceiver;
  address private _itfReceiver;
  address private _prismaDividendToken;

  mapping(address => uint256) private _balances;
  mapping(address => mapping(address => uint256)) private _allowances;
  mapping(address => bool) private _isFeeExempt;
  mapping(address => bool) private _automatedMarketMakerPairs;
  mapping(address => uint256) private _stakedPrisma;

  bool private _isInternalTransaction;
  bool private _stakingEnabled;

  uint256 private _totalSupply;
  uint256 private _buyLiquidityFee;
  uint256 private _buyTreasuryFee;
  uint256 private _buyItfFee;
  uint256 private _sellLiquidityFee;
  uint256 private _sellTreasuryFee;
  uint256 private _sellItfFee;
  uint256 private _totalStakedAmount;
  uint256 private _minSwapFees;

  uint256 private vestingSchedulesTotalAmount;
  bytes32[] private vestingSchedulesIds;
  mapping(address => uint256) private holdersVestingCount;
  mapping(bytes32 => VestingSchedule) private vestingSchedules;

  struct VestingSchedule {
    bool initialized;
    // beneficiary of tokens after they are released
    address beneficiary;
    // cliff period in seconds
    uint256 cliff;
    // start time of the vesting period
    uint256 start;
    // duration of the vesting period in seconds
    uint256 duration;
    // duration of a slice period for the vesting in seconds
    uint256 slicePeriodSeconds;
    // whether or not the vesting is revocable
    bool revocable;
    // total amount of tokens to be released at the end of the vesting
    uint256 amountTotal;
    // amount of tokens released
    uint256 released;
    // whether or not the vesting has been revoked
    bool revoked;
  }

  ///////////////////
  /// INITIALIZER ///
  ///////////////////

  /**
   * @dev Sets the values for {name} and {symbol}.
   * All two of these values are immutable: they can only be set once during
   * construction.
   */
  function init(
    address prismaDividendToken_,
    address tracker_
  ) public initializer {
    __Ownable_init();
    __ERC20_init("Prisma Finance", "PRISMA");

    // LOCAL TESTNET ONLY
    _treasuryReceiver = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    _itfReceiver = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

    _totalSupply = 10_000_000 * (10 ** 18);
    _minSwapFees = 1_000 * 10 ** 18;
    _buyLiquidityFee = 1;
    _buyTreasuryFee = 1;
    _buyItfFee = 2;
    _sellLiquidityFee = 1;
    _sellTreasuryFee = 1;
    _sellItfFee = 2;
    _stakingEnabled = true;

    _prismaDividendToken = prismaDividendToken_;
    _prismaDividendTracker = IPrismaDividendTracker(tracker_);

    _balances[msg.sender] = _totalSupply;

    _isFeeExempt[tracker_] = true;
  }

  /////////////
  /// ERC20 ///
  /////////////

  /**
   * @notice Returns the total number of tokens in existance.
   * @return uint256 token total supply
   */
  function totalSupply() public view virtual override returns (uint256) {
    return _totalSupply;
  }

  /**
   * @notice Returns the balance of a user.
   * @return uint256 account balance
   */
  function balanceOf(
    address account
  ) public view virtual override returns (uint256) {
    return _balances[account];
  }

  /**
   * @notice Transfers tokens from the caller to another user.
   * Requirements:
   * - to cannot be the zero address.
   * - the caller must have a balance of at least `amount`.
   * @return bool transfer success
   */
  function transfer(
    address to,
    uint256 amount
  ) public virtual override returns (bool) {
    address owner = _msgSender();
    _transferFrom(owner, to, amount);
    return true;
  }

  /**
   * @notice Returns how much a user can spend using a certain address.
   * @return uint256 amount allowed
   */
  function allowance(
    address owner,
    address spender
  ) public view virtual override returns (uint256) {
    return _allowances[owner][spender];
  }

  /**
   * @notice Approves an address to spend a certain amount of tokens.
   * Requirements:
   * - `spender` cannot be the zero address.
   * @dev If `amount` is the maximum `uint256`, the allowance is not updated on
   * `transferFrom`. This is semantically equivalent to an infinite approval.
   * @return bool success
   */
  function approve(
    address spender,
    uint256 amount
  ) public virtual override returns (bool) {
    address owner = _msgSender();
    require(owner != address(0), "ERC20: approve from the zero address");
    require(spender != address(0), "ERC20: approve to the zero address");

    _allowances[owner][spender] = amount;
    emit Approval(owner, spender, amount);
    return true;
  }

  /**
   * @notice Transfers tokens from one address to another.
   * Requirements:
   * - `from` and `to` cannot be the zero address.
   * - `from` must have a balance of at least `amount`.
   * - the caller must have allowance for ``from``'s tokens of at least
   * `amount`.
   * @dev Emits an {Approval} event indicating the updated allowance. This is not
   * required by the EIP. See the note at the beginning of {ERC20}.
   * Does not update the allowance if the current allowance is the maximum `uint256`.
   * @return bool success
   */
  function transferFrom(
    address from,
    address to,
    uint256 amount
  ) public virtual override returns (bool) {
    address spender = _msgSender();
    _spendAllowance(from, spender, amount);
    _transferFrom(from, to, amount);
    return true;
  }

  /**
   * @dev Moves `amount` of tokens from `from` to `to`.
   *
   * This internal function is equivalent to {transfer}, and can be used to
   * e.g. implement automatic token fees, slashing mechanisms, etc.
   *
   * Emits a {Transfer} event.
   *
   * Requirements:
   *
   * - `from` cannot be the zero address.
   * - `to` cannot be the zero address.
   * - `from` must have a balance of at least `amount`.
   */
  function _transferFrom(address from, address to, uint256 amount) internal {
    require(from != address(0), "ERC20: transfer from the zero address");
    require(to != address(0), "ERC20: transfer to the zero address");

    uint256 fromBalance = _balances[from];

    bool overMinSwapFees = balanceOf(address(_prismaDividendTracker)) >=
      _minSwapFees;

    uint256 fee;

    if (!_isInternalTransaction) {
      // Buy order
      if (_automatedMarketMakerPairs[from] && !_isFeeExempt[to]) {
        if (getTotalBuyFees() > 0) {
          fee = (amount * getTotalBuyFees()) / 100;
          _balances[address(_prismaDividendTracker)] += fee;
        }
      }
      // Sell order
      else if (_automatedMarketMakerPairs[to]) {
        if (_stakedPrisma[from] > 0) {
          uint256 nonStakedAmount = fromBalance - _stakedPrisma[from];
          require(nonStakedAmount >= amount, "You need to unstake first.");
        }

        if (!_isFeeExempt[from]) {
          if (getTotalSellFees() > 0) {
            fee = (amount * getTotalSellFees()) / 100;
            _balances[address(_prismaDividendTracker)] += fee;
            if (overMinSwapFees) {
              _isInternalTransaction = true;
              _prismaDividendTracker.swapFees();
              _isInternalTransaction = false;
            }
          }
        }
      } else {
        // Token Transfer
        if (_stakedPrisma[from] > 0) {
          uint256 nonStakedAmount = fromBalance - _stakedPrisma[from];
          require(nonStakedAmount >= amount, "You need to unstake first.");
        }
      }
    }

    uint256 amountReceived = amount - fee;
    unchecked {
      _balances[from] = fromBalance - amount;
      // Overflow not possible: the sum of all balances is capped by totalSupply, and the sum is preserved by
      // decrementing then incrementing.
      _balances[to] += amountReceived;
    }

    try _prismaDividendTracker.setBalance(from, balanceOf(from)) {} catch {}
    try _prismaDividendTracker.setBalance(to, balanceOf(to)) {} catch {}

    emit Transfer(from, to, amountReceived);
  }

  ///////////////
  /// Staking ///
  ///////////////

  /**
   * @dev Stake given `_amount` of Prisma Token
   */
  function stakePrisma(uint256 _amount) external {
    require(_stakingEnabled, "Staking is paused.");
    address _user = msg.sender;
    require(
      _balances[_user] >= _amount + _stakedPrisma[_user],
      "Not enough tokens to stake."
    );

    _stakedPrisma[_user] += _amount;
    _totalStakedAmount += _amount;
  }

  /**
   * @dev Unstake given `_amount` of Prisma Token
   */
  function unstakePrisma(uint256 _amount) external {
    require(_stakingEnabled, "Staking is paused.");
    address _user = msg.sender;
    require(_stakedPrisma[_user] >= _amount, "Not enough tokens to unstake.");

    _stakedPrisma[_user] -= _amount;
    _totalStakedAmount -= _amount;

    if (_stakedPrisma[_user] == 0) {
      delete _stakedPrisma[_user];
    }
  }

  /**
   * @dev Compounds `_prismaToCompound` after users choose to reinvest their tokens.
   * It expects to only be called by `_prismaDividendTracker` following reinvestment.
   */
  function compoundPrisma(
    address _staker,
    uint256 _prismaToCompound
  ) external override {
    require(
      msg.sender == address(_prismaDividendTracker),
      "NOT PRISMA_TRACKER"
    );
    require(_stakingEnabled, "Staking is paused.");
    _balances[_staker] += _prismaToCompound;
    _balances[msg.sender] -= _prismaToCompound;
    _stakedPrisma[_staker] += _prismaToCompound;
    _totalStakedAmount += _prismaToCompound;

    try
      _prismaDividendTracker.setBalance(msg.sender, balanceOf(msg.sender))
    {} catch {}
    try
      _prismaDividendTracker.setBalance(_staker, balanceOf(_staker))
    {} catch {}
  }

  ///////////////
  /// Vesting ///
  ///////////////

  /**
   * @notice Creates a new vesting schedule for a beneficiary.
   * @param _beneficiary address of the beneficiary to whom vested tokens are transferred
   * @param _start start time of the vesting period
   * @param _cliff duration in seconds of the cliff in which tokens will begin to vest
   * @param _duration duration in seconds of the period in which the tokens will vest
   * @param _slicePeriodSeconds duration of a slice period for the vesting in seconds
   * @param _revocable whether the vesting is revocable or not
   * @param _amount total amount of tokens to be released at the end of the vesting
   */
  function createVestingSchedule(
    address _beneficiary,
    uint256 _start,
    uint256 _cliff,
    uint256 _duration,
    uint256 _slicePeriodSeconds,
    bool _revocable,
    uint256 _amount
  ) external onlyOwner {
    require(balanceOf(address(this)) >= _amount, "Insufficient tokens.");
    require(_duration > 0, "Duration must be > 0.");
    require(_amount > 0, "Amount must be > 0.");
    require(_slicePeriodSeconds >= 1, "Period seconds must be >= 1.");
    require(_duration >= _cliff, "Duration must be >= cliff.");
    bytes32 vestingScheduleId = computeVestingScheduleIdForAddressAndIndex(
      _beneficiary,
      holdersVestingCount[_beneficiary]
    );
    uint256 cliff = _start + _cliff;
    vestingSchedules[vestingScheduleId] = VestingSchedule(
      true,
      _beneficiary,
      cliff,
      _start,
      _duration,
      _slicePeriodSeconds,
      _revocable,
      _amount,
      0,
      false
    );
    vestingSchedulesTotalAmount = vestingSchedulesTotalAmount + _amount;
    vestingSchedulesIds.push(vestingScheduleId);
    uint256 currentVestingCount = holdersVestingCount[_beneficiary];
    holdersVestingCount[_beneficiary] = currentVestingCount + 1;
  }

  /**
   * @notice Release vested amount of tokens.
   * @param vestingScheduleId the vesting schedule identifier
   * @param amount the amount to release
   */
  function release(bytes32 vestingScheduleId, uint256 amount) public {
    VestingSchedule storage vestingSchedule = vestingSchedules[
      vestingScheduleId
    ];
    bool isBeneficiary = msg.sender == vestingSchedule.beneficiary;

    address owner = owner();
    bool isReleasor = (msg.sender == owner);
    require(
      isBeneficiary || isReleasor,
      "Only beneficiary and owner can release vested tokens."
    );
    uint256 vestedAmount = _computeReleasableAmount(vestingSchedule);
    require(
      vestedAmount >= amount,
      "Insufficient tokens to release available."
    );
    vestingSchedule.released = vestingSchedule.released + amount;
    vestingSchedulesTotalAmount = vestingSchedulesTotalAmount - amount;
    transfer(vestingSchedule.beneficiary, amount);
  }

  /**
   * @dev Computes the releasable amount of tokens for a vesting schedule.
   * @return the amount of releasable tokens
   */
  function _computeReleasableAmount(
    VestingSchedule memory vestingSchedule
  ) internal view returns (uint256) {
    // Retrieve the current time.
    uint256 currentTime = block.timestamp;
    // If the current time is before the cliff, no tokens are releasable.
    if ((currentTime < vestingSchedule.cliff) || vestingSchedule.revoked) {
      return 0;
    }
    // If the current time is after the vesting period, all tokens are releasable,
    // minus the amount already released.
    else if (currentTime >= vestingSchedule.start + vestingSchedule.duration) {
      return vestingSchedule.amountTotal - vestingSchedule.released;
    }
    // Otherwise, some tokens are releasable.
    else {
      // 10% of tokens are immediately available.
      uint256 initialRelease = (vestingSchedule.amountTotal * 10) / 100;
      // Compute the number of full vesting periods that have elapsed.
      uint256 timeFromStart = currentTime - vestingSchedule.start;
      uint256 secondsPerSlice = vestingSchedule.slicePeriodSeconds;
      uint256 vestedSlicePeriods = timeFromStart / secondsPerSlice;
      uint256 vestedSeconds = vestedSlicePeriods * secondsPerSlice;
      // Compute the amount of tokens that are vested.
      uint256 vestedAmount = (vestingSchedule.amountTotal * vestedSeconds) /
        vestingSchedule.duration;
      // Subtract the amount already released and return.
      return vestedAmount + initialRelease - vestingSchedule.released;
    }
  }

  /**
   * @dev Computes the vesting schedule identifier for an address and an index.
   */
  function computeVestingScheduleIdForAddressAndIndex(
    address holder,
    uint256 index
  ) public pure returns (bytes32) {
    return keccak256(abi.encodePacked(holder, index));
  }

  ////////////////////////
  /// Setter Functions ///
  ////////////////////////

  function setBuyLiquidityFee(uint256 newValue) external onlyOwner {
    _buyLiquidityFee = newValue;
  }

  function setBuyTreasuryFee(uint256 newValue) external onlyOwner {
    _buyTreasuryFee = newValue;
  }

  function setBuyItfFee(uint256 newValue) external onlyOwner {
    _buyItfFee = newValue;
  }

  function setSellLiquidityFee(uint256 newValue) external onlyOwner {
    _sellLiquidityFee = newValue;
  }

  function setSellTreasuryFee(uint256 newValue) external onlyOwner {
    _sellTreasuryFee = newValue;
  }

  function setSellItfFee(uint256 newValue) external onlyOwner {
    _sellItfFee = newValue;
  }

  function setMinSwapFees(uint256 newValue) external onlyOwner {
    _minSwapFees = newValue;
  }

  function setAutomatedMarketPair(
    address _pair,
    bool _active
  ) external onlyOwner {
    _automatedMarketMakerPairs[_pair] = _active;
  }

  function updatePrismaDividendTracker(address newAddress) external onlyOwner {
    require(
      newAddress != address(_prismaDividendTracker),
      "The dividend tracker already has that address."
    );
    IPrismaDividendTracker new_IPrismaDividendTracker = IPrismaDividendTracker(
      newAddress
    );
    new_IPrismaDividendTracker.excludeFromDividends(
      address(new_IPrismaDividendTracker)
    );
    new_IPrismaDividendTracker.excludeFromDividends(address(this));
    _prismaDividendTracker = new_IPrismaDividendTracker;
  }

  function excludeFromDividend(address account) external onlyOwner {
    _prismaDividendTracker.excludeFromDividends(address(account));
  }

  function updateMinimumBalanceForDividends(
    uint256 newMinimumBalance
  ) external onlyOwner {
    _prismaDividendTracker.updateMinimumTokenBalanceForDividends(
      newMinimumBalance
    );
  }

  function updatePrismaDividendToken(address _newContract) external onlyOwner {
    _prismaDividendToken = _newContract;
    _prismaDividendTracker.setDividendTokenAddress(_newContract);
  }

  function setStakingStatus(bool status) external onlyOwner {
    _stakingEnabled = status;
  }

  ////////////////////////
  /// Getter Functions ///
  ////////////////////////

  function getTotalBuyFees() public view returns (uint256) {
    return _buyLiquidityFee + _buyTreasuryFee + _buyItfFee;
  }

  function getTotalSellFees() public view returns (uint256) {
    return _sellLiquidityFee + _sellTreasuryFee + _sellItfFee;
  }

  function getBuyLiquidityFee() external view returns (uint256) {
    return _buyLiquidityFee;
  }

  function getBuyTreasuryFee() external view returns (uint256) {
    return _buyTreasuryFee;
  }

  function getBuyItfFee() external view returns (uint256) {
    return _buyItfFee;
  }

  function getSellLiquidityFee() external view returns (uint256) {
    return _sellLiquidityFee;
  }

  function getSellTreasuryFee() external view returns (uint256) {
    return _sellTreasuryFee;
  }

  function getSellItfFee() external view returns (uint256) {
    return _sellItfFee;
  }

  function getMinSwapFees() external view returns (uint256) {
    return _minSwapFees;
  }

  function getOwner() external view returns (address) {
    return owner();
  }

  function getTreasuryReceiver() external view returns (address) {
    return _treasuryReceiver;
  }

  function getItfReceiver() external view returns (address) {
    return _itfReceiver;
  }

  function getPrismaDividendTracker() external view returns (address pair) {
    return address(_prismaDividendTracker);
  }

  function getTotalPrismaDividendsDistributed()
    external
    view
    returns (uint256)
  {
    return _prismaDividendTracker.getTotalDividendsDistributed();
  }

  function withdrawablePrismaDividendOf(
    address account
  ) external view returns (uint256) {
    return _prismaDividendTracker.withdrawableDividendOf(account);
  }

  function prismaDividendTokenBalanceOf(
    address account
  ) public view returns (uint256) {
    return _prismaDividendTracker.balanceOf(account);
  }

  function getAccountPrismaDividendsInfo(
    address account
  ) external view returns (address, int256, int256, uint256, uint256) {
    return _prismaDividendTracker.getAccount(account);
  }

  function getAccountPrismaDividendsInfoAtIndex(
    uint256 index
  ) external view returns (address, int256, int256, uint256, uint256) {
    return _prismaDividendTracker.getAccountAtIndex(index);
  }

  function getLastPrismaDividendProcessedIndex()
    external
    view
    returns (uint256)
  {
    return _prismaDividendTracker.getLastProcessedIndex();
  }

  function getNumberOfPrismaDividendTokenHolders()
    external
    view
    returns (uint256)
  {
    return _prismaDividendTracker.getNumberOfTokenHolders();
  }

  function getStakedPrisma(address _user) external view returns (uint256) {
    return _stakedPrisma[_user];
  }

  function getStakingStatus() external view returns (bool) {
    return _stakingEnabled;
  }

  function getTotalStakedAmount() external view returns (uint256) {
    return _totalStakedAmount;
  }

  function getVestingSchedule(
    bytes32 vestingScheduleId
  ) public view returns (VestingSchedule memory) {
    return vestingSchedules[vestingScheduleId];
  }

  function getVestingSchedulesCountByBeneficiary(
    address _beneficiary
  ) external view returns (uint256) {
    return holdersVestingCount[_beneficiary];
  }

  function getVestingSchedulesTotalAmount() external view returns (uint256) {
    return vestingSchedulesTotalAmount;
  }

  function getVestingSchedulesCount() public view returns (bytes32[] memory) {
    return vestingSchedulesIds;
  }
}
