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
    const [owner, user, user2] = await ethers.getSigners();

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

    return { comptroller, cEth, owner, user, user2 };
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

  describe("Borrow", function () {
  //   describe("Validations", function () {
  //     it("Should revert with the right error if called too soon", async function () {
  //       const { lock } = await loadFixture(deployOneYearLockFixture);

  //       await expect(lock.withdraw()).to.be.revertedWith(
  //         "You can't withdraw yet"
  //       );
  //     });

  //     it("Should revert with the right error if called from another account", async function () {
  //       const { lock, unlockTime, otherAccount } = await loadFixture(
  //         deployOneYearLockFixture
  //       );

  //       // We can increase the time in Hardhat Network
  //       await time.increaseTo(unlockTime);

  //       // We use lock.connect() to send a transaction from another account
  //       await expect(lock.connect(otherAccount).withdraw()).to.be.revertedWith(
  //         "You aren't the owner"
  //       );
  //     });

  //     it("Shouldn't fail if the unlockTime has arrived and the owner calls it", async function () {
  //       const { lock, unlockTime } = await loadFixture(
  //         deployOneYearLockFixture
  //       );

  //       // Transactions are sent using the first signer by default
  //       await time.increaseTo(unlockTime);

  //       await expect(lock.withdraw()).not.to.be.reverted;
  //     });
  //   });

  //   describe("Events", function () {
  //     it("Should emit an event on withdrawals", async function () {
  //       const { lock, unlockTime, lockedAmount } = await loadFixture(
  //         deployOneYearLockFixture
  //       );

  //       await time.increaseTo(unlockTime);

  //       await expect(lock.withdraw())
  //         .to.emit(lock, "Withdrawal")
  //         .withArgs(lockedAmount, anyValue); // We accept any value as `when` arg
  //     });
  //   });

  //   describe("Transfers", function () {
  //     it("Should transfer the funds to the owner", async function () {
  //       const { lock, unlockTime, lockedAmount, owner } = await loadFixture(
  //         deployOneYearLockFixture
  //       );

  //       await time.increaseTo(unlockTime);

  //       await expect(lock.withdraw()).to.changeEtherBalances(
  //         [owner, lock],
  //         [lockedAmount, -lockedAmount]
  //       );
  //     });
  //   });
  });
});
