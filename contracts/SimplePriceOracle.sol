// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.17;

// import "./CErc20.sol";
import "./interface/cToken.sol";
import "./cErc721.sol";

contract SimplePriceOracle {
  mapping(address => uint) prices;
  event PricePosted(address asset, uint previousPriceMantissa, uint requestedPriceMantissa, uint newPriceMantissa);

  function _getUnderlyingAddress(address _tokenAddress) private view returns (address) {
    address asset;
    if (compareStrings(ICToken(_tokenAddress).symbol(), "cETH")) {
      asset = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }else {
      asset = address(cErc721(_tokenAddress).underlyingAddress());
    }

    return asset;
  }

  function getUnderlyingPrice(ICToken cToken) public view returns (uint) {
    return prices[_getUnderlyingAddress(address(cToken))];
  }

  function setUnderlyingPrice(ICToken cToken, uint underlyingPriceMantissa) public {
    address asset = _getUnderlyingAddress(address(cToken));
    emit PricePosted(asset, prices[asset], underlyingPriceMantissa, underlyingPriceMantissa);
    prices[asset] = underlyingPriceMantissa;
  }

  function setDirectPrice(address asset, uint price) public {
    emit PricePosted(asset, prices[asset], price, price);
    prices[asset] = price;
  }

  function getNftUnderlyingPrice(cErc721 cNft) public view returns (uint) {
    return prices[_getUnderlyingAddress(address(cNft))];
  }
  
  function setNftPrice(cErc721 cNft, uint nftPriceMantissa) public {
    address asset = _getUnderlyingAddress(address(cNft));
    emit PricePosted(asset, prices[asset], nftPriceMantissa, nftPriceMantissa);
    prices[asset] = nftPriceMantissa;
  }

  // v1 price oracle interface for use as backing of proxy
  function assetPrices(address asset) external view returns (uint) {
    return prices[asset];
  }

  function compareStrings(string memory a, string memory b) internal pure returns (bool) {
    return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
  }
}
