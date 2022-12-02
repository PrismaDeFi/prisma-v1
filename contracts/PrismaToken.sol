// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20SnapshotUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract PrismaToken is ERC20SnapshotUpgradeable, OwnableUpgradeable {
  ///////////////
  // CONSTANTS //
  ///////////////

  address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
  address private constant ZERO = 0x0000000000000000000000000000000000000000;

  ///////////////
  // VARIABLES //
  ///////////////

  address public multisig;
  address public liquidityReceiver;
  address public treasuryReceiver;

  mapping(address => uint256) private _balances;
  mapping(address => mapping(address => uint256)) private _allowances;
  mapping(address => bool) private _isFeeExempt;
  mapping(address => bool) private _automatedMarketMakerPairs;
  mapping(address => uint256) private _stakedPrisma;
  mapping(address => bool) private _notStakingQualified;

  bool private _stakingEnabled;

  uint256 private _totalSupply;
  uint256 private _buyLiquidityFee;
  uint256 private _buyTreasuryFee;
  uint256 private _buyBurnFee;
  uint256 private _sellLiquidityFee;
  uint256 private _sellTreasuryFee;
  uint256 private _sellBurnFee;
  uint256 private _totalBuyFees =
    _buyLiquidityFee + _buyTreasuryFee + _buyBurnFee;
  uint256 private _totalSellFees =
    _sellLiquidityFee + _sellTreasuryFee + _sellBurnFee;
  uint256 private _minStakeAmount;

  /////////////////
  // INITIALIZER //
  /////////////////

  /**
   * @dev Sets the values for {name} and {symbol}.
   * All two of these values are immutable: they can only be set once during
   * construction.
   */
  function init() public initializer {
    __Ownable_init();
    __ERC20Snapshot_init();
    __ERC20_init("Prisma Finance", "PRISMA");

    liquidityReceiver = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // development wallet
    treasuryReceiver = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65; // development wallet
    multisig = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // development wallet
    _totalSupply = 100_000_000 * (10 ** 18);
    _buyLiquidityFee = 2;
    _buyTreasuryFee = 2;
    _sellLiquidityFee = 2;
    _sellTreasuryFee = 2;
    _minStakeAmount = 10 * (10 ** 18); //Need to discuss this number
    _stakingEnabled = true;

    _balances[msg.sender] = _totalSupply;
    _automatedMarketMakerPairs[
      0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
    ] = true; // development wallet
    _isFeeExempt[multisig] = true;
  }

  ///////////
  // ERC20 //
  ///////////

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
    _transfer(owner, to, amount);
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
    _approve(owner, spender, amount);
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
    _transfer(from, to, amount);
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
  function _transfer(
    address from,
    address to,
    uint256 amount
  ) internal virtual override {
    require(from != address(0), "ERC20: transfer from the zero address");
    require(to != address(0), "ERC20: transfer to the zero address");

    uint256 fromBalance = _balances[from];
    require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");

    uint256 fee;

    // Buy order
    if (_automatedMarketMakerPairs[from] && !_isFeeExempt[to]) {
      if (_buyLiquidityFee > 0) {
        uint256 liquityFee = (amount * _buyLiquidityFee) / 100;
        fee += liquityFee;
        _balances[liquidityReceiver] = liquityFee;
      }
      if (_buyTreasuryFee > 0) {
        uint256 treasuryFee = (amount * _buyTreasuryFee) / 100;
        fee += treasuryFee;
        _balances[treasuryReceiver] = treasuryFee;
      }
      if (_buyBurnFee > 0) {
        uint256 burnFee = (amount * _buyBurnFee) / 100;
        fee += burnFee;
        _balances[DEAD] = burnFee;
        //Or we can burn directly from supply, comment above and uncomment below
        //_totalSupply -= burnFee;
      }
    }
    // Sell order
    else if (_automatedMarketMakerPairs[to]) {
      if (_stakedPrisma[from] > 0) {
        uint256 nonStakedAmount = fromBalance - _stakedPrisma[from];
        require(nonStakedAmount >= amount, "You need to unstake first");
      }

      if (!_isFeeExempt[from]) {
        if (_sellLiquidityFee > 0) {
          uint256 liquityFee = (amount * _sellLiquidityFee) / 100;
          fee += liquityFee;
          _balances[liquidityReceiver] = liquityFee;
        }
        if (_sellTreasuryFee > 0) {
          uint256 treasuryFee = (amount * _sellTreasuryFee) / 100;
          fee += treasuryFee;
          _balances[treasuryReceiver] = treasuryFee;
        }
        if (_sellBurnFee > 0) {
          uint256 burnFee = (amount * _sellBurnFee) / 100;
          fee += burnFee;
          _balances[DEAD] = burnFee;
          //Or we can burn directly from supply, comment above and uncomment below
          //_totalSupply -= burnFee;
        }
      }
    } else {
      // Token Transfer
      if (_stakedPrisma[from] > 0) {
        uint256 nonStakedAmount = fromBalance - _stakedPrisma[from];
        require(nonStakedAmount >= amount, "You need to unstake first");
      }
    }

    _beforeTokenTransfer(from, to, amount);

    uint256 amountReceived = amount - fee;
    unchecked {
      _balances[from] = fromBalance - amount; // from will deduct full amount not the amountReceived
      // Overflow not possible: the sum of all balances is capped by totalSupply, and the sum is preserved by
      // decrementing then incrementing.
      _balances[to] += amountReceived;
    }

    emit Transfer(from, to, amountReceived);
  }

  function snapshot() external {
    require(msg.sender == multisig, "Only multisig can trigger snapshot");
    _snapshot();
  }

  //////////////
  // Staking //
  ////////////

  /**
   * @dev Stake given `_amount` of Prisma Token.
   *
   * To check:
   *
   * - Check for security issue and any attack.
   * - Make sure user can not sell/transfer the staked token.
   * - Do we need any event fired for future case?.
   * - Check `_minStakeAmount` before deployemnt and discuss with team.
   * - Do we need extra admin function to manage staking?
   * - Check if we used require statement correctly? Do we need more?
   * - Do we need maxAmount restrication as well?
   */
  function stakePrisma(uint256 _amount) external {
    require(_stakingEnabled, "Staking is paused");
    address _user = msg.sender;
    require(
      !_notStakingQualified[_user],
      "The address is not allowed to stake or unstake"
    );
    require(_balances[_user] >= _amount, "Not enough tokens to stake");
    require(
      _amount >= _minStakeAmount,
      "Amount is less than minimum required token"
    );

    _stakedPrisma[_user] += _amount;
  }

  /**
   * @dev Unstake given `_amount` of Prisma Token.
   *
   * To check:
   *
   * - Check for security issue and any attack.
   * - Do we need any event fired for future case?.
   * - Do we need `_minStakeAmount` constraint here too?
   * - Do we need extra admin function to manage unstaking?
   * - Check if we used require statement correctly? Do we need more?
   * - Do we need maxAmount restrication as well?
   */
  function unstakePrisma(uint256 _amount) external {
    require(_stakingEnabled, "Staking is paused");
    address _user = msg.sender;
    require(
      !_notStakingQualified[_user],
      "The address is not allowed to stake or unstake"
    );
    require(_stakedPrisma[_user] >= _amount, "Not enough tokens to unstake");

    _stakedPrisma[_user] -= _amount;

    if (_stakedPrisma[_user] == 0) {
      delete _stakedPrisma[_user];
    }
  }

  ///////////////////////
  // Setter Functions //
  /////////////////////

  function setBuyLiquidityFee(uint256 newValue) external onlyOwner {
    _buyLiquidityFee = newValue;
  }

  function setBuyTreasuryFee(uint256 newValue) external onlyOwner {
    _buyTreasuryFee = newValue;
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

  function setSellBurnFee(uint256 newValue) external onlyOwner {
    _sellBurnFee = newValue;
  }

  function setMinStakeAmount(uint256 newValue) external onlyOwner {
    _minStakeAmount = newValue;
  }

  function setStakingStatus(bool status) external onlyOwner {
    _stakingEnabled = status;
  }

  function setNotStakingQualified(
    address user,
    bool notQualified
  ) external onlyOwner {
    _notStakingQualified[user] = notQualified;
  }

  ///////////////////////
  // Getter Functions //
  /////////////////////

  function getBuyLiquidityFee() external view returns (uint256) {
    return _buyLiquidityFee;
  }

  function getBuyTreasuryFee() external view returns (uint256) {
    return _buyTreasuryFee;
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

  function getSellBurnFee() external view returns (uint256) {
    return _sellBurnFee;
  }

  function getStakedPrisma(address _user) external view returns (uint256) {
    return _stakedPrisma[_user];
  }

  function getMinStakeAmount() external view returns (uint256) {
    return _minStakeAmount;
  }

  function getStakingStatus() external view returns (bool) {
    return _stakingEnabled;
  }
}
