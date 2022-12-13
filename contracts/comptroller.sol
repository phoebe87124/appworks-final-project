// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.17;

import { Ownable } from '@openzeppelin/contracts/access/Ownable.sol';
import "./interface/cToken.sol";
import "./cErc721.sol";
import "./ExponentialNoError.sol";
import "./SimplePriceOracle.sol";
import "hardhat/console.sol";

contract Comptroller is Ownable, ExponentialNoError {
  event MarketListed(address cToken);
  event NftMarketListed(address cNft);
  event MarketEntered(address cNft, address borrower);

  struct Market {
    // Whether or not this market is listed
    bool isListed;

    //  Multiplier representing the most one can borrow against their collateral in this market.
    //  For instance, 0.9 to allow borrowing 90% of collateral value.
    //  Must be between 0 and 1, and stored as a mantissa.
    uint collateralFactorMantissa;

    // Per-market mapping of "accounts in this asset"
    mapping(address => bool) accountMembership;
  }

  struct AccountLiquidityLocalVars {
    uint sumCollateral;
    uint sumBorrowPlusEffects;
    uint cNftBalance;
    uint cTokenBalance;
    uint borrowBalance;
    uint exchangeRateMantissa;
    uint oraclePriceMantissa;
    Exp collateralFactor;
    Exp exchangeRate;
    Exp oraclePrice;
    Exp tokensToDenom;
  }

  ICToken[] public allMarkets;
  cErc721[] public allNftMarkets;
  mapping(address => Market) public markets;
  mapping(address => Market) public nftMarkets;
  mapping(address => cErc721[]) public accountAssets;

  SimplePriceOracle oracle;


  constructor(address oracleAddress) {
    oracle = SimplePriceOracle(oracleAddress);
  }

  function mintAllowed(address cToken) external view returns (uint) {
    if (!markets[cToken].isListed) {
      return 9;
    }
    return 0;
  }
  
  function mintNftAllowed(address cNft) external view returns (uint) {
    if (!nftMarkets[cNft].isListed) {
      return 9;
    }
    return 0;
  }

  function redeemAllowed(address cToken, address redeemer, uint redeemTokens) external view returns (uint) {
    if (!markets[cToken].isListed) {
      return 9;
    }

    /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
    if (!markets[cToken].accountMembership[redeemer]) {
      return 0;
    }

    /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
    (uint err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, ICToken(cToken), redeemTokens, 0);
    if (err != 0) {
      return err;
    }
    if (shortfall > 0) {
      return 4;
    }

    return 0;
  }

  function borrowAllowed(address cToken, address borrower, uint borrowAmount) external view returns (uint) {
    if (!markets[cToken].isListed) {
      return 9;
    }

    if (oracle.getUnderlyingPrice(ICToken(cToken)) == 0) {
      return 13;
    }

    (uint err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, ICToken(cToken), 0, borrowAmount);
    if (err != 0) {
      return err;
    }
    if (shortfall > 0) {
      return 4;
    }

    return 0;
  }

  function repayBorrowAllowed(
    address cToken,
    address payer,
    address borrower,
    uint repayAmount) external view returns (uint) {
    // Shh - currently unused
    payer;
    borrower;
    repayAmount;

    if (!markets[cToken].isListed) {
      return 9;
    }

    return 0;
  }

  function liquidateBorrowAllowed(
    address cTokenBorrowed,
    address cNftCollateral,
    uint tokenId,
    address liquidator,
    address borrower,
    uint repayToken) external view returns (uint) {
    // Shh - currently unused
    liquidator;

    if (!markets[cTokenBorrowed].isListed || !nftMarkets[cNftCollateral].isListed) {
      return 9;
    }

    require(cErc721(cNftCollateral).ownerOf(tokenId) == borrower, "Comptroller: token id not owned by borrower");

    ICToken cToken = ICToken(cTokenBorrowed);
    uint borrowBalance = cToken.borrowBalanceStored(borrower);

    // cToken -> underlying token
    Exp memory exchangeRate = Exp({mantissa: cToken.exchangeRateStored() });
    uint repayAmount = mul_ScalarTruncate(exchangeRate, repayToken);

    /* The borrower must have shortfall in order to be liquidatable */
    (uint err, , uint shortfall) = getAccountLiquidityInternal(borrower);
    if (err != 0) {
      return err;
    }

    if (shortfall == 0) {
      return 3;
    }

    /* The liquidator have to repay more than borrowBalance */
    if (repayAmount < borrowBalance) {
      return 17;
    }
    return 0;
  }

  function claimAllowed(
    address cToken,
    address claimer,
    uint256 tokenId) external view returns (uint) {
    // Shh - currently unused
    claimer;
    tokenId;

    if (!markets[cToken].isListed) {
      return 9;
    }

    return 0;
  }

  function supportMarket(address cToken) external onlyOwner returns (uint) {
    require(!markets[cToken].isListed, "Comptroller: market already listed");
    
    // Sanity check to make sure its really a CToken
    require(ICToken(cToken).isCToken(), "Comptroller: not cToken be listed"); 

    Market storage newMarket = markets[cToken];
    newMarket.isListed = true;
    newMarket.collateralFactorMantissa = 0.5e18;

    _addMarketInternal(cToken);

    emit MarketListed(cToken);

    return 0;
  }

  function _addMarketInternal(address cToken) internal {
    for (uint i = 0; i < allMarkets.length; i ++) {
      require(allMarkets[i] != ICToken(cToken), "Comptroller: market already added");
    }
    allMarkets.push(ICToken(cToken));
  }

  function supportNftMarket(address cNft) external onlyOwner returns (uint) {
    require(!nftMarkets[cNft].isListed, "Comptroller: market already listed");
    
    // Sanity check to make sure its really a CNft
    require(cErc721(cNft).isCNft(), "Comptroller: not cNft be listed"); 

    Market storage newMarket = nftMarkets[cNft];
    newMarket.isListed = true;
    newMarket.collateralFactorMantissa = 0.5e18;

    _addNftMarketInternal(cNft);
    emit NftMarketListed(cNft);

    return 0;
  }

  function _addNftMarketInternal(address cNft) internal {
    for (uint i = 0; i < allNftMarkets.length; i ++) {
      require(allNftMarkets[i] != cErc721(cNft), "Comptroller: nft market already added");
    }
    allNftMarkets.push(cErc721(cNft));
  }

  function enterMarkets(address[] memory cNfts) public returns (uint[] memory) {
    uint len = cNfts.length;

    uint[] memory results = new uint[](len);
    for (uint i = 0; i < len; i++) {
      cErc721 cNft = cErc721(cNfts[i]);

      results[i] = uint(addToMarketInternal(cNft, msg.sender));
    }

    return results;
  }

  function addToMarketInternal(cErc721 cNft, address borrower) internal returns (uint) {
    Market storage marketToJoin = nftMarkets[address(cNft)];

    if (!marketToJoin.isListed) {
      return 9;
    }

    if (marketToJoin.accountMembership[borrower] == true) {
      // already joined
      return 0;
    }

    marketToJoin.accountMembership[borrower] = true;
    accountAssets[borrower].push(cNft);

    emit MarketEntered(address(cNft), borrower);

    return 0;
  }

  function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
    (uint err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, ICToken(address(0)), 0, 0);

    return (err, liquidity, shortfall);
  }

  function getAccountLiquidityInternal(address account) internal view returns (uint, uint, uint) {
    return getHypotheticalAccountLiquidityInternal(account, ICToken(address(0)), 0, 0);
  }

  function getHypotheticalAccountLiquidityInternal(
    address account,
    ICToken cTokenModify,
    uint redeemTokens,
    uint borrowAmount
  ) internal view returns (uint, uint, uint) {

    AccountLiquidityLocalVars memory vars; // Holds all our calculation results
    uint oErr;

    // For each asset the account is in
    cErc721[] memory assets = accountAssets[account];
    for (uint i = 0; i < assets.length; i++) {
      cErc721 asset = assets[i];

      // Read the balances from the cNft
      (oErr, vars.cNftBalance) = asset.getAccountSnapshot(account);
      if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
        return (15, 0, 0);
      }
      
      vars.collateralFactor = Exp({mantissa: nftMarkets[address(asset)].collateralFactorMantissa});

      // Get the normalized price of the asset
      vars.oraclePriceMantissa = oracle.getNftUnderlyingPrice(asset);
      if (vars.oraclePriceMantissa == 0) {
        return (13, 0, 0);
      }
      
      // Pre-compute a conversion factor from tokens -> ether (normalized price value)
      vars.tokensToDenom = mul_(vars.collateralFactor, vars.oraclePriceMantissa);

      // sumCollateral += tokensToDenom * cTokenBalance
      vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.cNftBalance, vars.sumCollateral);
    }

    ICToken[] memory borrowMarkets = allMarkets;
    for (uint i = 0; i < borrowMarkets.length; i++) {
      ICToken cToken = borrowMarkets[i];
      (oErr, vars.cTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = cToken.getAccountSnapshot(account);
      if (oErr != 0) {
        return (15, 0, 0);
      }

      // vars.collateralFactor = Exp({mantissa: markets[address(cToken)].collateralFactorMantissa});
      vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

      // Get the normalized price of the asset
      vars.oraclePriceMantissa = oracle.getUnderlyingPrice(cToken);
      if (vars.oraclePriceMantissa == 0) {
        return (13, 0, 0);
      }
      vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

      // Pre-compute a conversion factor from tokens -> ether (normalized price value)
      // vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);
      vars.tokensToDenom = mul_(vars.exchangeRate, vars.oraclePrice);

      // sumBorrowPlusEffects += oraclePrice * borrowBalance
      vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

      // Calculate effects of interacting with cTokenModify
      if (cToken == cTokenModify) {
        // redeem effect
        // sumBorrowPlusEffects += tokensToDenom * redeemTokens
        vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

        // borrow effect
        // sumBorrowPlusEffects += oraclePrice * borrowAmount
        vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
      }
    }

    // These are safe, as the underflow condition is checked first
    if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
      return (0, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
    } else {
      return (0, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
    }
  }

  function getAccountAssets(address account) external view returns (cErc721[] memory assets) {
    return accountAssets[account];
  }
}
