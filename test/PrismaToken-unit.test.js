const { assert, expect } = require("chai")
const { deployments, ethers } = require("hardhat")

describe("PrismaToken Test", () => {
  let prismaToken, deployer, user, multisig, liquidity, treasury, market
  beforeEach(async () => {
    ;[deployer, user, multisig, liquidity, treasury, market] =
      await ethers.getSigners()

    await deployments.fixture("all")

    prismaToken = await ethers.getContract("PrismaToken", deployer)
    prismaMultisig = prismaToken.connect(multisig)
    await prismaMultisig.init()
    await prismaMultisig.transfer(
      deployer.address,
      ethers.utils.parseEther("1000000")
    )
    await prismaMultisig.transfer(
      market.address,
      ethers.utils.parseEther("1000000")
    )
    await prismaMultisig.transferOwnership(deployer.address)
  })

  describe("init", () => {
    it("initialized correctly", async () => {
      const name = await prismaToken.name()
      const symbol = await prismaToken.symbol()
      assert.equal(name.toString(), "Prisma Finance")
      assert.equal(symbol.toString(), "PRISMA")
    })
    it("cannot be reinizialized", async () => {
      await expect(prismaToken.init()).to.be.revertedWith(
        "Initializable: contract is already initialized"
      )
    })
  })

  describe("transfer", () => {
    it("can transfer", async () => {
      await prismaToken.transfer(user.address, ethers.utils.parseEther("10000"))
      const userBalance = await prismaToken.balanceOf(user.address)
      assert.equal(userBalance.toString(), ethers.utils.parseEther("10000"))
    })
    it("takes fees to", async () => {
      await prismaToken.transfer(
        market.address,
        ethers.utils.parseEther("10000")
      )
      assert.equal(
        (await prismaToken.balanceOf(liquidity.address)).toString(),
        ethers.utils.parseEther("200")
      )
      assert.equal(
        (await prismaToken.balanceOf(treasury.address)).toString(),
        ethers.utils.parseEther("200")
      )
      assert.equal(
        (await prismaToken.balanceOf(market.address)).toString(),
        ethers.utils.parseEther("1009600")
      )
      assert.equal(
        (await prismaToken.balanceOf(deployer.address)).toString(),
        ethers.utils.parseEther("990000")
      )
    })
    it("takes fees from", async () => {
      const prismaMarket = prismaToken.connect(market)
      await prismaMarket.transfer(
        deployer.address,
        ethers.utils.parseEther("10000")
      )
      assert.equal(
        (await prismaToken.balanceOf(liquidity.address)).toString(),
        ethers.utils.parseEther("200")
      )
      assert.equal(
        (await prismaToken.balanceOf(treasury.address)).toString(),
        ethers.utils.parseEther("200")
      )
      assert.equal(
        (await prismaToken.balanceOf(market.address)).toString(),
        ethers.utils.parseEther("990000")
      )
      assert.equal(
        (await prismaToken.balanceOf(deployer.address)).toString(),
        ethers.utils.parseEther("1009600")
      )
    })
    it("cannot sell staked balance", async () => {
      await prismaToken.transfer(user.address, ethers.utils.parseEther("10000"))
      const prismaUser = prismaToken.connect(user)
      await prismaUser.stakePrisma(ethers.utils.parseEther("5000"))
      await expect(
        prismaUser.transfer(market.address, ethers.utils.parseEther("7500"))
      ).to.be.rejectedWith("You need to unstake first")
    })
    it("cannot transfer staked balance", async () => {
      await prismaToken.transfer(user.address, ethers.utils.parseEther("10000"))
      const prismaUser = prismaToken.connect(user)
      await prismaUser.stakePrisma(ethers.utils.parseEther("5000"))
      await expect(
        prismaUser.transfer(deployer.address, ethers.utils.parseEther("7500"))
      ).to.be.rejectedWith("You need to unstake first")
    })
  })

  describe("snapshot", () => {
    it("snapshot can be retrieved", async () => {
      const prismaMultisig = prismaToken.connect(multisig)
      await prismaToken.transfer(
        multisig.address,
        ethers.utils.parseEther("500000")
      )
      await prismaMultisig.snapshot()
      await prismaToken.transfer(
        multisig.address,
        ethers.utils.parseEther("100000")
      )
      const deployerBalance = await prismaToken.balanceOfAt(deployer.address, 1)
      assert.equal(
        deployerBalance.toString(),
        ethers.utils.parseEther("500000")
      )
    })
    it("only works for multisig", async () => {
      const prismaMultisig = prismaToken.connect(multisig)
      const txResponse = await prismaMultisig.snapshot()
      const txReceipt = await txResponse.wait()
      await expect(prismaToken.snapshot()).to.be.revertedWith(
        "Only multisig can trigger snapshot"
      )
      assert.equal(txReceipt.events[0].event, "Snapshot")
    })
  })
  describe("stakePrisma", () => {
    it("staking must be enabled", async () => {
      await prismaToken.setStakingStatus(false)
      await expect(
        prismaToken.stakePrisma(ethers.utils.parseEther("10000"))
      ).to.be.revertedWith("Staking is paused")
    })
    it("must be qualified", async () => {
      await prismaToken.setNotStakingQualified(deployer.address, true)
      await expect(
        prismaToken.stakePrisma(ethers.utils.parseEther("10000"))
      ).to.be.revertedWith("The address is not allowed to stake or unstake")
    })
    it("cannot stake more tokens than owned", async () => {
      const prismaUser = prismaToken.connect(user)
      await expect(
        prismaUser.stakePrisma(ethers.utils.parseEther("10000"))
      ).to.be.revertedWith("Not enough tokens to stake")
    })
    it("must stake at least min amount", async () => {
      await expect(
        prismaToken.stakePrisma(ethers.utils.parseEther("1"))
      ).to.be.revertedWith("Amount is less than minimum required token")
    })
    it("can stake", async () => {
      await prismaToken.stakePrisma(ethers.utils.parseEther("10000"))
      assert.equal(
        (await prismaToken.getStakedPrisma(deployer.address)).toString(),
        ethers.utils.parseEther("10000")
      )
    })
  })
  describe("unstakePrisma", () => {
    it("cannot unstake more than staked", async () => {
      await expect(
        prismaToken.unstakePrisma(ethers.utils.parseEther("10000"))
      ).to.be.revertedWith("Not enough tokens to unstake")
    })
    it("can unstake", async () => {
      await prismaToken.stakePrisma(ethers.utils.parseEther("10000"))
      await prismaToken.unstakePrisma(ethers.utils.parseEther("5000"))
      assert.equal(
        (await prismaToken.getStakedPrisma(deployer.address)).toString(),
        ethers.utils.parseEther("5000")
      )
    })
  })
})
