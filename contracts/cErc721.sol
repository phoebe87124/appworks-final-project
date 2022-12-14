// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;
import { ERC721Enumerable } from '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "./comptroller.sol";

contract cErc721 is ERC721Enumerable {
  event Mint(address minter, uint tokenId);
  event Redeem(address _to, uint _tokenId);

  bool public constant isCNft = true;
  address public underlyingAddress;  // NFT address

  Comptroller comptroller;

  constructor(string memory _name, string memory _sysbol, address _underlyingAddress, address _comptrollerAddress) ERC721(_name, _sysbol) {
    underlyingAddress = _underlyingAddress;
    comptroller = Comptroller(_comptrollerAddress);
  }

  function mint(uint256 _tokenId) external {
    require(ERC721(underlyingAddress).ownerOf(_tokenId) == msg.sender, "cERC721: not NFT's owner");
    mintFresh(msg.sender, _tokenId);
  }

  function mintFresh(address _to, uint256 _tokenId) internal {
    require(comptroller.mintNftAllowed(address(this)) == 0, "Comptroller: nft market not listed");

    // Sanity checks
    require(_to == msg.sender, "cERC721: minter mismatch");

    ERC721(underlyingAddress).safeTransferFrom(msg.sender, address(this), _tokenId);
    _safeMint(_to, _tokenId);

    emit Mint(_to, _tokenId);
  }

  function redeem(uint _tokenId) external {
    require(ownerOf(_tokenId) == msg.sender, "cERC721: not NFT owner");
    require(comptroller.redeemNftAllowed(address(this), _tokenId, msg.sender) == 0, "Comptroller: redeem is not allowed");

    redeemFresh(msg.sender, _tokenId);
  }

  function redeemFresh(address _to, uint _tokenId) internal {
    ERC721(underlyingAddress).safeTransferFrom(address(this), _to, _tokenId);
    _burn(_tokenId);

    emit Redeem(_to, _tokenId);
  }

  function claim(address _to, uint _tokenId) external {
    require(comptroller.claimAllowed(msg.sender, _to, _tokenId) == 0, "Comptroller: claim is not allowed");

    redeemFresh(_to, _tokenId);
  }

  function getAccountSnapshot(address account) external view returns (uint, uint) {
    return (0, balanceOf(account));
  }

  function onERC721Received(address, address, uint256, bytes memory) public pure returns (bytes4) {
    return this.onERC721Received.selector;
  }
}