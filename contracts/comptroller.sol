// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.17;

import { Ownable } from '@openzeppelin/contracts/access/Ownable.sol';
import "./interface/cToken.sol";
import "./ExponentialNoError.sol";
import "./SimplePriceOracle.sol";
import "hardhat/console.sol";

contract Comptroller is Ownable, ExponentialNoError {
  event MarketListed(address cToken);

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
  mapping(address => Market) public markets;
  mapping(address => ICToken[]) public accountAssets;

  SimplePriceOracle oracle;


  constructor(address oracleAddress) {
    oracle = SimplePriceOracle(oracleAddress);
  }

  function mintAllowed(address cToken) external view returns (uint) {
    if (!markets[cToken].isListed) {
      return 1;
    }
    return 0;
  }

  function redeemAllowed(address cToken, address redeemer, uint redeemTokens) external view returns (uint) {
    if (!markets[cToken].isListed) {
      return 1;
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

  function supportMarket(address cToken) external onlyOwner returns (uint) {
    require(!markets[cToken].isListed, "Comptroller: market already listed");
    
    // Sanity check to make sure its really a CToken
    require(ICToken(cToken).isCToken(), "Comptroller: not cToken be listed"); 

    Market storage newMarket = markets[cToken];
    newMarket.isListed = true;
    newMarket.collateralFactorMantissa = 0;

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

  function getHypotheticalAccountLiquidityInternal(
    address account,
    ICToken cTokenModify,
    uint redeemTokens,
    uint borrowAmount
  ) internal view returns (uint, uint, uint) {

    AccountLiquidityLocalVars memory vars; // Holds all our calculation results
    uint oErr;

    // For each asset the account is in
    ICToken[] memory assets = accountAssets[account];
    for (uint i = 0; i < assets.length; i++) {
      ICToken asset = assets[i];

      // Read the balances and exchange rate from the cToken
      (oErr, vars.cTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
      if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
        return (15, 0, 0);
      }
      vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
      vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

      // Get the normalized price of the asset
      vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
      if (vars.oraclePriceMantissa == 0) {
        return (13, 0, 0);
      }
      vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

      // Pre-compute a conversion factor from tokens -> ether (normalized price value)
      vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

      // sumCollateral += tokensToDenom * cTokenBalance
      vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.cTokenBalance, vars.sumCollateral);

      // sumBorrowPlusEffects += oraclePrice * borrowBalance
      vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

      // Calculate effects of interacting with cTokenModify
      if (asset == cTokenModify) {
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
}
