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
  event Borrow(address borrower, uint borrowAmount, uint accountBorrowsNew, uint totalBorrowsNew);
  event RepayBorrow(address payer, address borrower, uint actualRepayAmount, uint accountBorrowsNew, uint totalBorrowsNew);
  event LiquidateBorrow(address _liquidator, address _borrower, uint _repayToken, address _cNftCollateral);
  event AuctionStart(address _nftCollateral, uint _tokenId, address _bidder, uint _bidAmount);
  event AuctionBid(address _nftCollateral, uint _tokenId, address _bidder, uint _bidAmount);

  struct BorrowSnapshot {
    uint principal;
    uint interestIndex;
  }

  struct NftAuction {
    address bidder;
    uint256 amount;
    uint256 time;
  }

  bool public isCToken = true;

  // Maximum borrow rate that can ever be applied (.0005% / block)
  uint256 internal constant borrowRateMaxMantissa = 0.0005e16;
  uint256 internal constant initialExchangeRateMantissa = 1e18;

  uint256 accrualBlockNumber;
  uint256 totalBorrows;
  uint256 totalReserves;
  uint256 borrowIndex;
  uint256 reserveFactorMantissa;

  mapping(address => BorrowSnapshot) internal accountBorrows;
  mapping(address => mapping(uint => NftAuction)) public auctions;

  InterestRateModel interestRateModel;
  Comptroller comptroller;
  
  constructor(address _interestRateModelAddress, address _comptrollerAddress) {
    accrualBlockNumber = getBlockNumber();
    totalBorrows = 0;
    totalReserves = 0;
    borrowIndex = 1e18;
    // init related contract
    interestRateModel = InterestRateModel(_interestRateModelAddress);
    comptroller = Comptroller(_comptrollerAddress);
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

  // ================== MINT ==================
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

  // ================== REDEEM ==================
  function redeem(uint _amount) external {
    require(_amount <= balanceOf(msg.sender), "cEther: redeem amount exceeds balance");
    redeemInternal(_amount);
  }

  function redeemInternal(uint _redeemAmount) internal {
    accrueInterest();
    redeemFresh(msg.sender, _redeemAmount, 0);
  }

  function redeemUnderlying(uint _amount) external {
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

  // ================== BORROW ==================
  function borrow(uint _borrowAmount) external {
    borrowInternal(_borrowAmount);
  }

  function borrowInternal(uint _borrowAmount) internal {
    accrueInterest();
    borrowFresh(payable(msg.sender), _borrowAmount);
  }

  function borrowFresh(address payable _borrower, uint _borrowAmount) internal nonReentrant {
    require(comptroller.borrowAllowed(address(this), _borrower, _borrowAmount) == 0, "Comptroller: borrow not allowed");
    require(accrualBlockNumber == getBlockNumber(), "cEther: Wrong Block Number");
    require(getCashPrior() >= _borrowAmount, "cEther: insufficient cash");

    /*
      * We calculate the new borrower and total borrow balances, failing on overflow:
      *  accountBorrowNew = accountBorrow + borrowAmount
      *  totalBorrowsNew = totalBorrows + borrowAmount
      */
    uint accountBorrowsPrev = borrowBalanceStoredInternal(_borrower);
    uint accountBorrowsNew = accountBorrowsPrev + _borrowAmount;
    uint totalBorrowsNew = totalBorrows + _borrowAmount;

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /*
      * We write the previously calculated values into storage.
      *  Note: Avoid token reentrancy attacks by writing increased borrow before external transfer.
    `*/
    accountBorrows[_borrower].principal = accountBorrowsNew;
    accountBorrows[_borrower].interestIndex = borrowIndex;
    totalBorrows = totalBorrowsNew;

    cErc721[] memory collaterals = comptroller.getAccountAssets(_borrower);
    for (uint i = 0; i < collaterals.length; i++) {
      require(collaterals[i].isApprovedForAll(_borrower, address(this)), "cEther: collaterals not set approval to cEther");
      // collaterals[i].setApprovalForAll(address(this), true);
    }
    payable(msg.sender).transfer(_borrowAmount);

    emit Borrow(_borrower, _borrowAmount, accountBorrowsNew, totalBorrowsNew);
  }

  // ================== REPAY ==================
  function repayBorrow() external payable {
    repayBorrowInternal(msg.sender, msg.value);
  }

  function repayBorrowBehalf(address _borrower) external payable {
    repayBorrowBehalfInternal(_borrower, msg.value);
  }

  function repayBorrowInternal(address _borrower, uint _repayAmount) internal {
    accrueInterest();
    repayBorrowFresh(msg.sender, _borrower, _repayAmount);
  }
  
  function repayBorrowBehalfInternal(address _borrower, uint _repayAmount) internal {
    accrueInterest();
    repayBorrowFresh(msg.sender, _borrower, _repayAmount);
  }

  function repayBorrowFresh(address _payer, address _borrower, uint _repayAmount) internal nonReentrant returns (uint) {
    require(comptroller.repayBorrowAllowed(address(this), _payer, _borrower, _repayAmount) == 0, "Comptroller: repay not allowed");
    require(accrualBlockNumber == getBlockNumber(), "cEther: Wrong Block Number");

    /* We fetch the amount the borrower owes, with accumulated interest */
    uint accountBorrowsPrev = borrowBalanceStoredInternal(_borrower);

    uint repayAmountFinal = _repayAmount > accountBorrowsPrev ? accountBorrowsPrev : _repayAmount;

    uint accountBorrowsNew = accountBorrowsPrev - repayAmountFinal;
    uint totalBorrowsNew = totalBorrows - repayAmountFinal;

    /* We write the previously calculated values into storage */
    accountBorrows[_borrower].principal = accountBorrowsNew;
    accountBorrows[_borrower].interestIndex = borrowIndex;
    totalBorrows = totalBorrowsNew;

    emit RepayBorrow(_payer, _borrower, repayAmountFinal, accountBorrowsNew, totalBorrowsNew);

    return repayAmountFinal;
  }

  // ================== LIQUIDATE ==================
  // repay cToken
  function liquidateBorrow(address _borrower, uint256 _repayToken, cErc721 _cNftCollateral, uint _tokenId) external {
    liquidateBorrowInternal(_borrower, _repayToken, _cNftCollateral, _tokenId);
  }

  function liquidateBorrowInternal(address _borrower, uint _repayToken, cErc721 _cNftCollateral, uint _tokenId) internal nonReentrant {
    accrueInterest();
    liquidateBorrowFresh(msg.sender, _borrower, _repayToken, _cNftCollateral, _tokenId);
  }

  function liquidateBorrowFresh(address _liquidator, address _borrower, uint _repayToken, cErc721 _cNftCollateral, uint _tokenId) internal {
    require(comptroller.liquidateBorrowAllowed(address(this), address(_cNftCollateral), _tokenId, _liquidator, _borrower, _repayToken) == 0, "Comptroller: liquidate not allowed");
    require(accrualBlockNumber == getBlockNumber(), "cEther: Wrong Block Number");
    require(_borrower != _liquidator, "cEther: can not liquidate yourself");
    
    // Lock repay tokens for init Auction
    (bool success) = transfer(address(this), _repayToken);

    // transfer borrower's all Collaterals to cErc721
    cErc721[] memory collaterals = comptroller.getAccountAssets(_borrower);
    for (uint i = 0; i < collaterals.length; i++) {
      uint balanceOf = collaterals[i].balanceOf(_borrower);

      for (uint tokenIndex = 0; tokenIndex < balanceOf; tokenIndex++) {
        uint tokenId = collaterals[i].tokenOfOwnerByIndex(_borrower, tokenIndex);
        collaterals[i].safeTransferFrom(_borrower, address(collaterals[i]), tokenId);

        /* each Nft collateral starts an auction
        /  liquidator 可自動參與指定 _cNftCollateral 的競標，起標價為 _repayToken
        /  其他起標價為 0，起標者為 cNft 合約
        */
        bool isLiquidatorWant = address(collaterals[i]) == address(_cNftCollateral);
        uint bidAmount = isLiquidatorWant ? _repayToken : 0;
        address bidder = isLiquidatorWant ? _liquidator : address(collaterals[i]);
        startNftAuction(address(collaterals[i]), tokenId, bidder, bidAmount);
      }
    }

    emit LiquidateBorrow(_liquidator, _borrower, _repayToken, address(_cNftCollateral));
  }

  function startNftAuction(address _nftCollateral, uint _tokenId, address _bidder, uint _bidAmount) internal {
    NftAuction memory newAuction = NftAuction(_bidder, _bidAmount, block.timestamp);
    auctions[_nftCollateral][_tokenId] = newAuction;

    emit AuctionStart(_nftCollateral, _tokenId, _bidder, _bidAmount);
  }

  function bidNftAuction(address _nftCollateral, uint _tokenId, uint _bidAmount) external {
    NftAuction memory auction = auctions[_nftCollateral][_tokenId];
    require(auction.time > 0, "cEther: invalid auction");
    require(auction.time + 1 days >= block.timestamp, "cEther: auction ended");
    require(_bidAmount > auction.amount, "cEther: bid amount must larger than current amount");

    address previousBidder = auction.bidder;
    uint previousAmount = auction.amount;

    // update auction data
    auction.bidder = msg.sender;
    auction.amount = _bidAmount;
    auctions[_nftCollateral][_tokenId] = auction;

    // transfer previous bidder cEth back
    _transfer(address(this), previousBidder, previousAmount);
    
    // transfer msg.sender cEth in
    _transfer(msg.sender, address(this), _bidAmount);

    emit AuctionBid(_nftCollateral, _tokenId, msg.sender, _bidAmount);
  }

  function claimAuction(address _nftCollateral, uint _tokenId) external {
    NftAuction memory auction = auctions[_nftCollateral][_tokenId];
    require(auction.time + 1 days < block.timestamp, "cEther: auction is not ended");
    require(msg.sender == auction.bidder, "cEther: only bidder can claim NFT");

    cErc721(_nftCollateral).claim(msg.sender, _tokenId);

    delete auctions[_nftCollateral][_tokenId];
  }

  function exchangeRateStored() public view returns (uint) {
    return exchangeRateStoredInternal();
  }

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

  function borrowBalanceStored(address account) public view returns (uint) {
    return borrowBalanceStoredInternal(account);
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