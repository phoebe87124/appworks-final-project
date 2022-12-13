const { loadFixture, mineUpTo } = require("@nomicfoundation/hardhat-network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");
const { ethers } = require("hardhat");

function toWei(ether) {
  return ethers.utils.parseUnits(ether.toString(), 18)
} 

describe("NFT lending", function () {
  // deploy without other operations
  async function deployFixture() {
    const [owner, user, user2, user3, user4] = await ethers.getSigners();

    const simplePriceOracleFactory = await ethers.getContractFactory("SimplePriceOracle")
    simplePriceOracle = await simplePriceOracleFactory.deploy()
    await simplePriceOracle.deployed()
    
    const comptrollerFactory = await ethers.getContractFactory("Comptroller")
    comptroller = await comptrollerFactory.deploy(simplePriceOracle.address)
    await comptroller.deployed()

    const interestRateModelFactory = await ethers.getContractFactory("WhitePaperInterestRateModel")
    interestRateModel = await interestRateModelFactory.deploy(toWei(0), toWei(0))
    await interestRateModel.deployed()

    const cEthFactory = await ethers.getContractFactory("cEther")
    cEth = await cEthFactory.deploy(interestRateModel.address, comptroller.address)
    await cEth.deployed()

    return { comptroller, cEth, owner, user, user2, user3, user4, simplePriceOracle };
  }

  // deploy and add cEth to market
  async function afterEnterMarketFixture() {
    const { comptroller, cEth, owner, user, user2 } = await loadFixture(deployFixture);
    comptroller.supportMarket(cEth.address)

    return { comptroller, cEth, owner, user, user2 };
  }

  describe("Deployment", function () {
    it("Should set the right owner of comptroller", async function () {
      const { comptroller, owner } = await loadFixture(deployFixture);

      expect(await comptroller.owner()).to.equal(owner.address);
    });
  });

  describe("provide ETH liquidity", function () {
    it("Should revert if not enter market", async function () {
      const { cEth } = await loadFixture(deployFixture);
      await expect(cEth.mint({ value: toWei(1) })).to.be.revertedWith("Comptroller: Market not listed")
    });

    it("Should revert if enter market not by owner", async function () {
      const { comptroller, cEth, user } = await loadFixture(deployFixture);
      await expect(comptroller.connect(user).supportMarket(cEth.address)).to.be.revertedWith("Ownable: caller is not the owner")
    });

    it("Should revert if enter market with token is not cToken", async function () {
      const { comptroller } = await loadFixture(deployFixture);

      const erc20Factory = await ethers.getContractFactory("ERC20")
      tToken = await erc20Factory.deploy("test token", "tToken")
      await tToken.deployed()
      await expect(comptroller.supportMarket(tToken.address)).to.be.reverted
    });
    
    it("Mint revert with 0 Ether", async function () {
      const { cEth, user } = await loadFixture(deployFixture);
      await expect(cEth.connect(user).mint()).to.be.revertedWith("cEther: Ether required")
    });

    it("Mint & Redeem successfully with Ethers", async function () {
      const { cEth, user, user2 } = await loadFixture(afterEnterMarketFixture);
      // ======== MINT ========

      // user mint for 1 cETH
      const userMintAmount = toWei(1)
      await expect(cEth.connect(user).mint({value: userMintAmount}))
      .emit(cEth, "Mint")
      .withArgs(user.address, userMintAmount, userMintAmount);

      expect(await cEth.balanceOf(user.address)).to.equal(userMintAmount)
      expect(await cEth.totalSupply()).to.equal(userMintAmount)

      // user2 mint for 2 cETH
      const user2MintAmount = toWei(2)
      await expect(cEth.connect(user2).mint({value: user2MintAmount}))
      .emit(cEth, "Mint")
      .withArgs(user2.address, user2MintAmount, user2MintAmount);

      expect(await cEth.balanceOf(user2.address)).to.equal(user2MintAmount)
      expect(await cEth.totalSupply()).to.equal(toWei(3))


      // ======== REDEEM ========

      // user1 redeem ETH of 1 cETH
      await expect(cEth.connect(user).redeem(userMintAmount))
      .emit(cEth, "Redeem")
      .withArgs(user.address, userMintAmount, userMintAmount);

      expect(await cEth.balanceOf(user.address)).to.equal(0)
      expect(await cEth.totalSupply()).to.equal(toWei(2))

      // user2 redeem 1 ETH
      await expect(cEth.connect(user2).redeemUnderlying(toWei(1)))
      .emit(cEth, "Redeem")
      .withArgs(user2.address, toWei(1), toWei(1));

      expect(await cEth.balanceOf(user2.address)).to.equal(toWei(1))
      expect(await cEth.totalSupply()).to.equal(toWei(1))
    });
  });

  describe("Borrow", function() {
    const baycAddress = "0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D"
    const baycTokenId = 12
    const baycOwnerAddress = "0x50EF16A9167661DC2500DDde8f83937C1ba4CD5f"
    const binanceAddress = '0x28C6c06298d514Db089934071355E5743bf21d60'
    let comptroller, cEth, owner, user, user2, user3, user4, cNft, bayc, simplePriceOracle
    before(async function() {
      // provide 100 ETH to cETH pool
      ({ comptroller, cEth, owner, user, user2, user3, user4, simplePriceOracle } = await loadFixture(deployFixture))
      const ethLiquidityAmount = toWei(100)
      await comptroller.supportMarket(cEth.address)
      await cEth.mint({value: ethLiquidityAmount})
      expect(await cEth.balanceOf(owner.address)).to.equal(ethLiquidityAmount)
      expect(await cEth.totalSupply()).to.equal(ethLiquidityAmount)

      // get BAYC NFT
      bayc = await ethers.getContractAt("ERC721", baycAddress);

      // deploy cBAYC NFT
      const cNftFactory = await ethers.getContractFactory("cErc721")
      cNft = await cNftFactory.deploy("comp BAYC", "cBAYC", baycAddress, comptroller.address)
      await cNft.deployed()
    })
    
    it ("Revert if market not list", async function() {
      const baycSigner = await ethers.getImpersonatedSigner(baycOwnerAddress)
      await expect(cNft.connect(baycSigner).mint(baycTokenId)).to.be.revertedWith("Comptroller: nft market not listed")
    })

    it ("Mint cNft successfully", async function() {
      const baycSigner = await ethers.getImpersonatedSigner(baycOwnerAddress)
      await comptroller.supportNftMarket(cNft.address)
      await bayc.connect(baycSigner).approve(cNft.address, baycTokenId)
      await expect(cNft.connect(baycSigner).mint(baycTokenId))
      .emit(cNft, "Mint")
      .withArgs(baycOwnerAddress, baycTokenId)

      expect(await bayc.ownerOf(baycTokenId)).to.equal(cNft.address)
      expect(await cNft.ownerOf(baycTokenId)).to.equal(baycOwnerAddress)
    })

    it ("Enter market with BAYC#12", async function() {
      const baycSigner = await ethers.getImpersonatedSigner(baycOwnerAddress)
      await expect(comptroller.connect(baycSigner).enterMarkets([cNft.address]))
      .emit(comptroller, "MarketEntered")
      .withArgs(cNft.address, baycOwnerAddress)
    })

    it ("Borrow failed if amount exceeds collateral amounts", async function() {
      const baycSigner = await ethers.getImpersonatedSigner(baycOwnerAddress)
      await simplePriceOracle.setNftPrice(cNft.address, toWei(89776.19))
      await simplePriceOracle.setUnderlyingPrice(cEth.address, toWei(1273.06))
      
      await cNft.connect(baycSigner).setApprovalForAll(cEth.address, true)
      await expect(cEth.connect(baycSigner).borrow(toWei(36))).to.be.reverted
    })

    it ("Borrow successfully", async function() {
      const borrowAmount = toWei(10)
      const baycSigner = await ethers.getImpersonatedSigner(baycOwnerAddress)
      
      await cNft.connect(baycSigner).setApprovalForAll(cEth.address, true)
      await expect(cEth.connect(baycSigner).borrow(borrowAmount))
      .emit(cEth, "Borrow")
      .withArgs(baycOwnerAddress, borrowAmount, borrowAmount, borrowAmount)
      .to.changeEtherBalance(baycOwnerAddress, borrowAmount)
    })

    it ("Repay successfully", async function() {
      const repayAmount = toWei(5)
      const baycSigner = await ethers.getImpersonatedSigner(baycOwnerAddress)
      const binanceSigner = await ethers.getImpersonatedSigner(binanceAddress)
      
      await expect(cEth.connect(baycSigner).repayBorrow({value: repayAmount}))
      .emit(cEth, "RepayBorrow")
      .withArgs(baycOwnerAddress, baycOwnerAddress, repayAmount, toWei(5), toWei(5))
      .to.changeEtherBalance(baycOwnerAddress, -repayAmount)
      .to.changeEtherBalance(cEth.address, repayAmount)

      await expect(cEth.connect(binanceSigner).repayBorrowBehalf(baycOwnerAddress, {value: repayAmount}))
      .emit(cEth, "RepayBorrow")
      .withArgs(binanceAddress, baycOwnerAddress, repayAmount, 0, 0)
      .to.changeEtherBalance(binanceAddress, -repayAmount)
      .to.changeEtherBalance(cEth.address, repayAmount)
    })

    it ("Liquidate and start auction successfully", async function() {
      const borrowAmount = toWei(30)
      const baycSigner = await ethers.getImpersonatedSigner(baycOwnerAddress)
      
      await cEth.connect(baycSigner).borrow(borrowAmount)

      await simplePriceOracle.setNftPrice(cNft.address, toWei(70018.30))

      await expect(cEth.connect(user2).mint({value: toWei(80)}))
      .to.emit(cEth, "Mint")

      const cEthBalance = await cEth.balanceOf(user2.address)

      await cEth.connect(user2).approve(cEth.address, toWei(1000))
      await expect(cEth.connect(user2).liquidateBorrow(baycOwnerAddress, cEthBalance, cNft.address, baycTokenId))
      .emit(cEth, "LiquidateBorrow")
      .withArgs(user2.address, baycOwnerAddress, cEthBalance, cNft.address)
      .emit(cEth, "AuctionStart")
      .withArgs(cNft.address, baycTokenId, user2.address, cEthBalance)

      // NFT collatoral has transferred to cNft
      expect(await cNft.balanceOf(cNft.address)).to.equal(1)
      expect(await cNft.balanceOf(baycOwnerAddress)).to.equal(0)

      let auction = await cEth.auctions(cNft.address, baycTokenId)
      expect(auction[0]).is.equal(user2.address)
      expect(auction[1]).is.equal(cEthBalance)
    })

    it ("user3 attend auction successfully", async function() {
      const bidAmount = toWei(90)
      
      let previousAuction = await cEth.auctions(cNft.address, baycTokenId)
      await cEth.connect(user3).mint({value: bidAmount})
      await expect(cEth.connect(user3).bidNftAuction(cNft.address, baycTokenId, bidAmount))
      .to.changeTokenBalances(
        cEth,
        [user2.address, user3.address],
        [previousAuction.amount, "-90000000000000000000"]
      )
      .to.emit(cEth, "AuctionBid")
      .withArgs(cNft.address, baycTokenId, user3.address, bidAmount);
    })

    it ("user4 attend auction and claim NFT successfully", async function() {
      const bidAmount = toWei(95)
      
      let previousAuction = await cEth.auctions(cNft.address, baycTokenId)
      await cEth.connect(user4).mint({value: bidAmount})
      await expect(cEth.connect(user4).bidNftAuction(cNft.address, baycTokenId, bidAmount))
      .to.changeTokenBalances(
        cEth,
        [user3.address, user4.address],
        [previousAuction.amount, "-95000000000000000000"]
      )
      .to.emit(cEth, "AuctionBid")
      .withArgs(cNft.address, baycTokenId, user4.address, bidAmount)

      await ethers.provider.send("evm_increaseTime", [1 * 24 * 60 * 60]); // 1 day
      await expect(cEth.connect(user4).claimAuction(cNft.address, baycTokenId))
      .emit(cNft, "Redeem")
      .withArgs(user4.address, baycTokenId)

      // cNft burned
      await expect(cNft.ownerOf(baycTokenId)).to.be.reverted
      // Nft claim successfully
      expect(await bayc.ownerOf(baycTokenId)).to.equal(user4.address)
    })
  });
});
