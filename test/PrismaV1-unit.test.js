const { assert, expect } = require("chai")
const { deployments, ethers } = require("hardhat")

describe("PrismaV1 Test", () => {
  let prismaToken, busd, deployer, user, multisig, liquidity, treasury, market
  beforeEach(async () => {
    ;[deployer, user, multisig, liquidity, treasury, market] =
      await ethers.getSigners()

    await deployments.fixture("all")

    prismaToken = await ethers.getContract("PrismaToken", deployer)
    busd = await ethers.getContract("MockBUSDToken", deployer)
    wbnb = await ethers.getContract("MockWBNBToken", deployer)

    const factoryAbi =
      require("@uniswap/v2-core/build/UniswapV2Factory.json").abi
    const factoryBytecode =
      require("@uniswap/v2-core/build/UniswapV2Factory.json").bytecode
    const factoryFactory = new ethers.ContractFactory(
      factoryAbi,
      factoryBytecode,
      deployer
    )
    this.factory = await factoryFactory.deploy(deployer.address)
    await this.factory.deployTransaction.wait()

    const routerAbi =
      require("@uniswap/v2-periphery/build/UniswapV2Router02.json").abi
    const routerBytecode =
      require("@uniswap/v2-periphery/build/UniswapV2Router02.json").bytecode
    const routerFactory = new ethers.ContractFactory(
      routerAbi,
      routerBytecode,
      deployer
    )
    this.router = await routerFactory.deploy(this.factory.address, wbnb.address)
    await this.router.deployTransaction.wait()

    prismaMultisig = prismaToken.connect(multisig)
    await prismaMultisig.init(busd.address, this.router.address)
    await prismaMultisig.transfer(
      deployer.address,
      ethers.utils.parseEther("100000000")
    )
    await prismaMultisig.transfer(
      market.address,
      ethers.utils.parseEther("1000000")
    )
    await prismaMultisig.transferOwnership(deployer.address)

    await busd.transfer(prismaToken.address, ethers.utils.parseEther("1000000"))
  })
  describe("constructor", () => {
    it("initialized correctly", async () => {
      const name = await prismaToken.name()
      const symbol = await prismaToken.symbol()
      assert.equal(name.toString(), "Prisma Finance")
      assert.equal(symbol.toString(), "PRISMA")
      assert.equal(
        (await prismaToken.totalSupply()).toString(),
        ethers.utils.parseEther("100000000")
      )
      assert.equal((await prismaToken.getPrismaClaimWait()).toString(), "60")
    })
    it("cannot be reinizialized", async () => {
      await expect(
        prismaToken.init(busd.address, this.router.address)
      ).to.be.revertedWith("Initializable: contract is already initialized")
    })
  })
  describe("addLiquidity", () => {
    it("adds liquidity", async () => {
      const tracker = await prismaToken.getTracker()
      await prismaToken.transfer(tracker, ethers.utils.parseEther("1000000"))
      await busd.transfer(tracker, ethers.utils.parseEther("1000000"))
      await prismaToken.addPrismaLiquidity(
        ethers.utils.parseEther("1000000"),
        ethers.utils.parseEther("1000000")
      )
      const [reserveA, reserveB] = await prismaToken.checkPrismaLiquidity()
      assert.equal(reserveA.toString(), ethers.utils.parseEther("1000000"))
      assert.equal(reserveB.toString(), ethers.utils.parseEther("1000000"))
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
        ethers.utils.parseEther("99990000")
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
        ethers.utils.parseEther("100009600")
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
        ethers.utils.parseEther("50000000")
      )
      await prismaMultisig.snapshot()
      await prismaToken.transfer(
        multisig.address,
        ethers.utils.parseEther("100000")
      )
      const deployerBalance = await prismaToken.balanceOfAt(deployer.address, 1)
      assert.equal(
        deployerBalance.toString(),
        ethers.utils.parseEther("50000000")
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
  describe("setDividends", () => {
    it("sets dividends", async () => {
      await prismaToken.setDividends(deployer.address, deployer.address)
      assert.equal(
        (await prismaToken.balanceOf(deployer.address)).toString(),
        (
          await prismaToken.prismaDividendTokenBalanceOf(deployer.address)
        ).toString()
      )
    })
  })
  describe("processDividends", () => {
    it("distributes dividends", async () => {
      await prismaToken.setDividends(deployer.address, deployer.address)
      await prismaToken.processDividends()
      assert.equal(
        BigInt(await prismaToken.getTotalPrismaDividendsDistributed()) /
          BigInt(10 ** 18),
        BigInt(1000000)
      )
      assert.equal(
        BigInt(
          await prismaToken.withdrawablePrismaDividendOf(deployer.address)
        ) / BigInt(10 ** 18),
        BigInt(999999)
      )
    })
    it("corrects dividends", async () => {
      await prismaToken.setDividends(deployer.address, deployer.address)
      await prismaToken.processDividends()
      await prismaToken.transfer(
        user.address,
        ethers.utils.parseEther("1000000")
      )
      await prismaToken.setDividends(deployer.address, user.address)
      assert.equal(
        (
          await prismaToken.prismaDividendTokenBalanceOf(user.address)
        ).toString(),
        ethers.utils.parseEther("1000000")
      )
      assert.equal(
        await prismaToken.withdrawablePrismaDividendOf(user.address),
        0
      )
    })
  })
  describe("claim", () => {
    it("can withdraw dividends", async () => {
      await prismaToken.setDividends(deployer.address, deployer.address)
      await prismaToken.processDividends()
      const balanceBefore = await busd.balanceOf(deployer.address)
      const dividends = await prismaToken.withdrawablePrismaDividendOf(
        deployer.address
      )
      await prismaToken.claim()
      assert(dividends > 0)
      assert.equal(
        BigInt(await busd.balanceOf(deployer.address)) / BigInt(10 ** 18),
        BigInt(balanceBefore) / BigInt(10 ** 18) +
          BigInt(dividends) / BigInt(10 ** 18)
      )
    })
    it("cannot withdraw dividends twice", async () => {
      await prismaToken.setDividends(deployer.address, deployer.address)
      await prismaToken.processDividends()
      await prismaToken.claim()
      assert.equal(
        (
          await prismaToken.withdrawablePrismaDividendOf(deployer.address)
        ).toString(),
        "0"
      )
    })
  })
  describe("processDividendTracker", () => {
    it("processes dividends automatically", async () => {
      await prismaToken.setDividends(deployer.address, deployer.address)
      await prismaToken.processDividends()
      const balanceBefore = await busd.balanceOf(deployer.address)
      const dividends = await prismaToken.withdrawablePrismaDividendOf(
        deployer.address
      )
      await prismaToken.processDividendTracker("1000000")
      assert(dividends > 0)
      assert.equal(
        BigInt(await busd.balanceOf(deployer.address)) / BigInt(10 ** 18),
        BigInt(balanceBefore) / BigInt(10 ** 18) +
          BigInt(dividends) / BigInt(10 ** 18)
      )
    })
    ///////////////////////////////////////
    // Uncomment to fry your motherboard //
    ///////////////////////////////////////
    it("processes dividends to multiple holders", async () => {
      for (let i = 0; i < 1000; i++) {
        wallet = ethers.Wallet.createRandom()
        wallet = wallet.connect(ethers.provider)
        await deployer.sendTransaction({
          to: wallet.address,
          value: ethers.utils.parseEther("0.5"),
        })
        await prismaToken.transfer(
          wallet.address,
          ethers.utils.parseEther("100000")
        )
        await prismaToken.setDividends(deployer.address, wallet.address)
      }
      await prismaToken.processDividends()
      const balanceBefore = await busd.balanceOf(deployer.address)
      const dividends = await prismaToken.withdrawablePrismaDividendOf(
        deployer.address
      )
      await prismaToken.processDividendTracker("30000000")
      assert.equal(
        BigInt(await busd.balanceOf(deployer.address)) / BigInt(10 ** 18),
        BigInt(balanceBefore) / BigInt(10 ** 18) +
          BigInt(dividends) / BigInt(10 ** 18)
      )
    })
  })
})
