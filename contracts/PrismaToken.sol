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

  address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
  address private constant ZERO = 0x0000000000000000000000000000000000000000;

  /////////////////
  /// VARIABLES ///
  /////////////////

  IPrismaDividendTracker private _prismaDividendTracker;

  address private _multisig;
  address private _liquidityReceiver;
  address private _treasuryReceiver;
  address private _itfReceiver;
  address private _burnReceiver;
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
  uint256 private _buyBurnFee;
  uint256 private _sellLiquidityFee;
  uint256 private _sellTreasuryFee;
  uint256 private _sellItfFee;
  uint256 private _sellBurnFee;
  uint256 private _totalStakedAmount;
  uint256 private _minSwapFees;

  //////////////
  /// Events ///
  //////////////

  event TreasuryFeeCollected(uint256 amount);
  event BurnFeeCollected(uint256 amount);
  event PrismaDividendTracker_Updated(
    address indexed newAddress,
    address indexed oldAddress
  );
  event PrismaDividendEnabled_Updated(bool enabled);

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
    _liquidityReceiver = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    _treasuryReceiver = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    _itfReceiver = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;
    _multisig = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

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

    _isFeeExempt[_multisig] = true;
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
          if (_buyBurnFee > 0) {
            uint256 buyBurn = (fee * _buyBurnFee) / getTotalBuyFees();
            _balances[DEAD] += buyBurn;
          }
        }
      }
      // Sell order
      else if (_automatedMarketMakerPairs[to]) {
        if (_stakedPrisma[from] > 0) {
          uint256 nonStakedAmount = fromBalance - _stakedPrisma[from];
          require(nonStakedAmount >= amount, "You need to unstake first");
        }

        if (!_isFeeExempt[from]) {
          if (getTotalSellFees() > 0) {
            fee = (amount * getTotalSellFees()) / 100;
            _balances[address(_prismaDividendTracker)] += fee;
            if (_sellBurnFee > 0) {
              uint256 sellBurn = (fee * _sellBurnFee) / getTotalSellFees();
              _balances[DEAD] += sellBurn;
            }
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
          require(nonStakedAmount >= amount, "You need to unstake first");
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
    require(_stakingEnabled, "Staking is paused");
    address _user = msg.sender;
    require(
      _balances[_user] >= _amount + _stakedPrisma[_user],
      "Not enough tokens to stake"
    );

    _stakedPrisma[_user] += _amount;
    _totalStakedAmount += _amount;
  }

  /**
   * @dev Unstake given `_amount` of Prisma Token
   */
  function unstakePrisma(uint256 _amount) external {
    require(_stakingEnabled, "Staking is paused");
    address _user = msg.sender;
    require(_stakedPrisma[_user] >= _amount, "Not enough tokens to unstake");

    _stakedPrisma[_user] -= _amount;
    _totalStakedAmount -= _amount;

    if (_stakedPrisma[_user] == 0) {
      delete _stakedPrisma[_user];
    }
  }

  function compoundPrisma(
    address _staker,
    uint256 _prismaToCompound
  ) external override {
    require(
      msg.sender == address(_prismaDividendTracker),
      "NOT PRISMA_TRACKER"
    );
    require(_stakingEnabled, "Staking is paused");
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

  function setBuyBurnFee(uint256 newValue) external onlyOwner {
    _buyBurnFee = newValue;
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

  function setSellBurnFee(uint256 newValue) external onlyOwner {
    _sellBurnFee = newValue;
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
      "The dividend tracker already has that address"
    );
    IPrismaDividendTracker new_IPrismaDividendTracker = IPrismaDividendTracker(
      newAddress
    );
    new_IPrismaDividendTracker.excludeFromDividends(
      address(new_IPrismaDividendTracker)
    );
    new_IPrismaDividendTracker.excludeFromDividends(address(this));
    emit PrismaDividendTracker_Updated(
      newAddress,
      address(new_IPrismaDividendTracker)
    );
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
    return _buyLiquidityFee + _buyTreasuryFee + _buyItfFee + _buyBurnFee;
  }

  function getTotalSellFees() public view returns (uint256) {
    return _sellLiquidityFee + _sellTreasuryFee + _sellItfFee + _sellBurnFee;
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

  function getBuyBurnFee() external view returns (uint256) {
    return _buyBurnFee;
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

  function getSellBurnFee() external view returns (uint256) {
    return _sellBurnFee;
  }

  function getOwner() external view returns (address) {
    return owner();
  }

  function getMultisig() external view returns (address) {
    return _multisig;
  }

  function getTreasuryReceiver() external view returns (address) {
    return _treasuryReceiver;
  }

  function getItfReceiver() external view returns (address) {
    return _itfReceiver;
  }

  function getBurnReceiver() external view returns (address) {
    return _burnReceiver;
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
}
