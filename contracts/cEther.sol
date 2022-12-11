// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;
import { ERC20 } from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import { ReentrancyGuard } from '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import "./InterestRateModel.sol";
import "./comptroller.sol";
import "./ExponentialNoError.sol";
import "hardhat/console.sol";

// staking Eth for liquidity
contract cEther is ERC20("cEther", "cETH"), ExponentialNoError, ReentrancyGuard {
  event AccrueInterest(uint cashPrior, uint interestAccumulated, uint borrowIndex, uint totalBorrows);
  event Mint(address minter, uint actualMintAmount, uint mintTokens);
  event Redeem(address redeemer, uint redeemAmount, uint redeemTokens);

  bool public isCToken = true;

  // Maximum borrow rate that can ever be applied (.0005% / block)
  uint256 internal constant borrowRateMaxMantissa = 0.0005e16;
  uint256 internal constant initialExchangeRateMantissa = 1e18;

  struct BorrowSnapshot {
    uint principal;
    uint interestIndex;
  }
  mapping(address => BorrowSnapshot) internal accountBorrows;

  uint256 accrualBlockNumber;
  uint256 totalBorrows;
  uint256 totalReserves;
  uint256 borrowIndex;
  uint256 reserveFactorMantissa;
  InterestRateModel interestRateModel;
  Comptroller comptroller;
  
  constructor(address interestRateModelAddress, address comptrollerAddress) {
    accrualBlockNumber = getBlockNumber();
    totalBorrows = 0;
    totalReserves = 0;
    borrowIndex = 1e18;
    // init related contract
    interestRateModel = InterestRateModel(interestRateModelAddress);
    comptroller = Comptroller(comptrollerAddress);
  }

  function getBlockNumber() internal view returns (uint) {
    return block.number;
  }

  function getCashPrior() internal view returns (uint) {
    return address(this).balance - msg.value;
  }

  // same as compound
  function accrueInterest() virtual public returns (uint) {
    /* Remember the initial block number */
    uint currentBlockNumber = getBlockNumber();
    uint accrualBlockNumberPrior = accrualBlockNumber;

    /* Short-circuit accumulating 0 interest */
    if (accrualBlockNumberPrior == currentBlockNumber) {
      return 0;
    }

    /* Read the previous values out of storage */
    uint cashPrior = getCashPrior();
    uint borrowsPrior = totalBorrows;
    uint reservesPrior = totalReserves;
    uint borrowIndexPrior = borrowIndex;

    /* Calculate the current borrow interest rate */
    uint borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
    require(borrowRateMantissa <= borrowRateMaxMantissa, "borrow rate is absurdly high");

    /* Calculate the number of blocks elapsed since the last accrual */
    uint blockDelta = currentBlockNumber - accrualBlockNumberPrior;

    /*
      * Calculate the interest accumulated into borrows and reserves and the new index:
      *  simpleInterestFactor = borrowRate * blockDelta
      *  interestAccumulated = simpleInterestFactor * totalBorrows
      *  totalBorrowsNew = interestAccumulated + totalBorrows
      *  totalReservesNew = interestAccumulated * reserveFactor + totalReserves
      *  borrowIndexNew = simpleInterestFactor * borrowIndex + borrowIndex
      */

    Exp memory simpleInterestFactor = mul_(Exp({mantissa: borrowRateMantissa}), blockDelta);
    uint interestAccumulated = mul_ScalarTruncate(simpleInterestFactor, borrowsPrior);
    uint totalBorrowsNew = interestAccumulated + borrowsPrior;
    uint totalReservesNew = mul_ScalarTruncateAddUInt(Exp({mantissa: reserveFactorMantissa}), interestAccumulated, reservesPrior);
    uint borrowIndexNew = mul_ScalarTruncateAddUInt(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /* We write the previously calculated values into storage */
    accrualBlockNumber = currentBlockNumber;
    borrowIndex = borrowIndexNew;
    totalBorrows = totalBorrowsNew;
    totalReserves = totalReservesNew;

    /* We emit an AccrueInterest event */
    emit AccrueInterest(cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew);

    return 0;
  }
  function mint() external payable {
    require(msg.value > 0, "cEther: Ether required");
    mintInternal(msg.value);
  }

  function mintInternal(uint _mintAmount) internal {
    accrueInterest();
    mintFresh(msg.sender, _mintAmount);
  }

  function mintFresh(address _to, uint256 _mintAmount) internal nonReentrant {
    require(comptroller.mintAllowed(address(this)) == 0, "Comptroller: Market not listed");
    require(accrualBlockNumber == getBlockNumber(), "cEther: Wrong Block Number");

    Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal()});

    // Sanity checks
    require(_to == msg.sender, "cEther: minter mismatch");
    require(_mintAmount == msg.value, "cEther: value mismatch");

    uint mintTokens = div_(_mintAmount, exchangeRate);
    _mint(_to, mintTokens);

    emit Mint(_to, msg.value, mintTokens);
  }

  function redeem(uint _amount) external {
    require(_amount > 0 && _amount <= balanceOf(msg.sender), "cEther: invalid redeem amount");
    redeemInternal(_amount);
  }

  function redeemInternal(uint _redeemAmount) internal {
    accrueInterest();
    redeemFresh(msg.sender, _redeemAmount, 0);
  }

  function redeemUnderlying(uint _amount) external {
    require(_amount > 0, "cEther: invalid redeem amount");
    redeemUnderlyingInternal(_amount);
  }

  function redeemUnderlyingInternal(uint _redeemAmount) internal {
    accrueInterest();
    redeemFresh(msg.sender, 0, _redeemAmount);
  }

  function redeemFresh(address _to, uint _redeemToken, uint _redeemAmount) internal nonReentrant {
    require(_redeemToken == 0 || _redeemAmount == 0, "one of redeemTokensIn or redeemAmountIn must be zero");

    Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal() });

    uint redeemTokens;
    uint redeemAmount;
    if (_redeemToken > 0) {
      redeemTokens = _redeemToken;
      redeemAmount = mul_ScalarTruncate(exchangeRate, _redeemToken);
    } else {
      redeemTokens = div_(_redeemAmount, exchangeRate);
      redeemAmount = _redeemAmount;
    }

    require(comptroller.redeemAllowed(address(this), _to, redeemTokens) == 0, "Comptroller: redeem not allowed");
    require(accrualBlockNumber == getBlockNumber(), "cEther: Wrong Block Number");
    require(getCashPrior() >= redeemAmount, "cEther: insufficient cash");

    _burn(msg.sender, redeemTokens);
    payable(msg.sender).transfer(redeemAmount);

    emit Redeem(_to, redeemAmount, redeemTokens);
  }

  // function borrow(uint borrowAmount) external {
  //   // cEth in
  //   // eth out
  // }

  // function repayBorrow() external {
  //   // eth in
  //   // cEth out
  // }

  // function liquidate() external payable {
  //   // eth in
  //   // nft auction
  // }

  function exchangeRateStoredInternal() internal view returns (uint) {
    uint _totalSupply = totalSupply();
    if (_totalSupply == 0) {
      return initialExchangeRateMantissa;
    } else {
      uint totalCash = getCashPrior();
      uint cashPlusBorrowsMinusReserves = totalCash + totalBorrows - totalReserves;
      uint exchangeRate = cashPlusBorrowsMinusReserves * expScale / _totalSupply;

      return exchangeRate;
    }
  }

  function getAccountSnapshot(address account) external view returns (uint, uint, uint, uint) {
    return (
      0,
      balanceOf(account),
      borrowBalanceStoredInternal(account),
      exchangeRateStoredInternal()
    );
  }

  function borrowBalanceStoredInternal(address account) internal view returns (uint) {
    /* Get borrowBalance and borrowIndex */
    BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

    /* If borrowBalance = 0 then borrowIndex is likely also 0.
      * Rather than failing the calculation with a division by 0, we immediately return 0 in this case.
      */
    if (borrowSnapshot.principal == 0) {
        return 0;
    }

    /* Calculate new borrow balance using the interest index:
      *  recentBorrowBalance = borrower.borrowBalance * market.borrowIndex / borrower.borrowIndex
      */
    uint principalTimesIndex = borrowSnapshot.principal * borrowIndex;
    return principalTimesIndex / borrowSnapshot.interestIndex;
  }
}