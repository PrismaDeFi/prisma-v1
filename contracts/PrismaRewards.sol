// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

import "./PrismaDividendTracker.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";

contract PrismaRewards is Ownable {
  ///////////////
  // Variables //
  ///////////////

  PrismaDividendTracker private prismaDividendTracker;

  address private prismaToken;
  address private prismaDividendToken;

  bool private processDividendStatus = true;
  bool private prismaDividendEnabled = true;

  uint256 private gasForProcessing = 300000;

  ////////////
  // Events //
  ////////////

  event PrismaDividendTracker_Updated(
    address indexed newAddress,
    address indexed oldAddress
  );
  event PrismaDividendEnabled_Updated(bool enabled);
  event GasForProcessing_Updated(
    uint256 indexed newValue,
    uint256 indexed oldValue
  );

  event SendDividends(uint256 amount);

  event PrismaDividendTracker_Processed(
    uint256 iterations,
    uint256 claims,
    uint256 lastProcessedIndex,
    bool indexed automatic,
    uint256 gas,
    address indexed processor
  );

  /////////////////
  // Constructor //
  /////////////////

  constructor(
    address _prismaToken,
    address _prismaDividendToken,
    address _router
  ) {
    prismaToken = _prismaToken;
    prismaDividendToken = _prismaDividendToken;
    prismaDividendTracker = new PrismaDividendTracker(
      _prismaDividendToken,
      _router,
      _prismaToken
    );
  }

  //////////////////////////
  // Dividends Processing //
  //////////////////////////

  function claim() external {
    prismaDividendTracker.processAccount(payable(msg.sender), false);
  }

  function transfer(address from, address to) external {
    uint256 fromBalance = IERC20(prismaToken).balanceOf(from);
    uint256 toBalance = IERC20(prismaToken).balanceOf(to);
    prismaDividendTracker.setBalance(payable(from), fromBalance);
    prismaDividendTracker.setBalance(payable(to), toBalance);
  }

  function processDividends() public {
    uint256 balance = prismaDividendTracker.balanceOf(msg.sender);
    if (processDividendStatus) {
      if (balance > 10000000000) {
        // 0,00000001 BNB
        uint256 dividends = IERC20(prismaDividendToken).balanceOf(
          address(this)
        );
        transferDividends(
          prismaDividendToken,
          address(prismaDividendTracker),
          prismaDividendTracker,
          dividends
        );
      }
    }
  }

  function processDividendTracker(uint256 gas) public onlyOwner {
    (
      uint256 Iterations,
      uint256 Claims,
      uint256 LastProcessedIndex
    ) = prismaDividendTracker.process(gas);
    emit PrismaDividendTracker_Processed(
      Iterations,
      Claims,
      LastProcessedIndex,
      false,
      gas,
      tx.origin
    );
  }

  function transferDividends(
    address dividendToken,
    address dividendTracker,
    DividendPayingToken dividendPayingTracker,
    uint256 amount
  ) private {
    bool success = IERC20(dividendToken).transfer(dividendTracker, amount);
    if (success) {
      dividendPayingTracker.distributeDividends(amount);
      emit SendDividends(amount);
    }
  }

  //////////////////////
  // Setter Functions //
  //////////////////////

  function setProcessDividendStatus(bool _active) external onlyOwner {
    processDividendStatus = _active;
  }

  function setPrismaDividendEnabled(bool _enabled) external onlyOwner {
    prismaDividendEnabled = _enabled;
  }

  function setPrismaDividendToken(
    address _prismaDividendToken
  ) external onlyOwner {
    prismaDividendToken = _prismaDividendToken;
  }

  function updatePrismaDividendTracker(address newAddress) external onlyOwner {
    require(
      newAddress != address(prismaDividendTracker),
      "The dividend tracker already has that address"
    );
    PrismaDividendTracker new_prismaDividendTracker = PrismaDividendTracker(
      payable(newAddress)
    );
    new_prismaDividendTracker.excludeFromDividends(
      address(new_prismaDividendTracker)
    );
    new_prismaDividendTracker.excludeFromDividends(address(this));
    emit PrismaDividendTracker_Updated(
      newAddress,
      address(new_prismaDividendTracker)
    );
    prismaDividendTracker = new_prismaDividendTracker;
  }

  function excludeFromDividend(address account) public onlyOwner {
    prismaDividendTracker.excludeFromDividends(address(account));
  }

  function updateGasForProcessing(uint256 newValue) external onlyOwner {
    require(
      newValue != gasForProcessing,
      "Cannot update gasForProcessing to same value"
    );
    gasForProcessing = newValue;
    emit GasForProcessing_Updated(newValue, gasForProcessing);
  }

  function updateMinimumBalanceForDividends(
    uint256 newMinimumBalance
  ) external onlyOwner {
    prismaDividendTracker.updateMinimumTokenBalanceForDividends(
      newMinimumBalance
    );
  }

  function updateClaimWait(uint256 claimWait) external onlyOwner {
    prismaDividendTracker.updateClaimWait(claimWait);
  }

  function updatePrismaDividendToken(
    address _newContract,
    uint256 gas
  ) external onlyOwner {
    prismaDividendTracker.process(gas);
    prismaDividendToken = _newContract;
    prismaDividendTracker.setDividendTokenAddress(_newContract);
  }

  //////////////////////
  // Getter Functions //
  //////////////////////

  function getPrismaClaimWait() external view returns (uint256) {
    return prismaDividendTracker.claimWait();
  }

  function getTotalPrismaDividendsDistributed()
    external
    view
    returns (uint256)
  {
    return prismaDividendTracker.totalDividendsDistributed();
  }

  function withdrawablePrismaDividendOf(
    address account
  ) external view returns (uint256) {
    return prismaDividendTracker.withdrawableDividendOf(account);
  }

  function prismaDividendTokenBalanceOf(
    address account
  ) public view returns (uint256) {
    return prismaDividendTracker.balanceOf(account);
  }

  function getAccountPrismaDividendsInfo(
    address account
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
    )
  {
    return prismaDividendTracker.getAccount(account);
  }

  function getAccountPrismaDividendsInfoAtIndex(
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
    )
  {
    return prismaDividendTracker.getAccountAtIndex(index);
  }

  function getLastPrismaDividendProcessedIndex()
    external
    view
    returns (uint256)
  {
    return prismaDividendTracker.getLastProcessedIndex();
  }

  function getNumberOfPrismaDividendTokenHolders()
    external
    view
    returns (uint256)
  {
    return prismaDividendTracker.getNumberOfTokenHolders();
  }

  function getTracker() external view returns (address pair) {
    return address(prismaDividendTracker);
  }

  function PrismaPair() external view returns (address) {
    return prismaDividendTracker.prismaPair();
  }

  function GetPrismaPair() external view returns (address) {
    return prismaDividendTracker.getPrismaPair();
  }

  function addPrismaLiquidity(
    uint256 prismaAmount,
    uint256 busdAmount
  ) external {
    prismaDividendTracker.addLiquidity(prismaAmount, busdAmount);
  }

  function checkPrismaLiquidity()
    external
    view
    returns (uint112, uint112, uint32)
  {
    return prismaDividendTracker.checkLiquidity();
  }
}
