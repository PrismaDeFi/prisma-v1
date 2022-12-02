const { assert, expect } = require("chai")
const { deployments, ethers } = require("hardhat")

describe("PrismaRewards Test", () => {
  let prisma, busd, rewards, deployer, user
  beforeEach(async () => {
    ;[deployer, user] = await ethers.getSigners()

    await deployments.fixture("all")

    prisma = await ethers.getContract("MockPrismaToken", deployer)
    busd = await ethers.getContract("MockBUSDToken", deployer)
    wbnb = await ethers.getContract("MockBUSDToken", deployer)
    rewards = await ethers.getContract("PrismaRewards", deployer)

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

    await busd.transfer(rewards.address, ethers.utils.parseEther("1000000"))
  })
  describe("constructor", () => {
    it("initialized correctly", async () => {
      assert.equal(
        (await prisma.totalSupply()).toString(),
        ethers.utils.parseEther("100000000")
      )
      assert.equal(
        (await busd.totalSupply()).toString(),
        ethers.utils.parseEther("100000000")
      )
      assert.equal((await rewards.getPrismaClaimWait()).toString(), "60")
    })
  })
  describe("addLiquidity", () => {
    it("adds liquidity", async () => {
      const tracker = await rewards.getTracker()
      await prisma.transfer(tracker, ethers.utils.parseEther("1000000"))
      await busd.transfer(tracker, ethers.utils.parseEther("1000000"))
      await rewards.addPrismaLiquidity(
        ethers.utils.parseEther("1000000"),
        ethers.utils.parseEther("1000000")
      )
      const [reserveA, reserveB] = await rewards.checkPrismaLiquidity()
      assert.equal(reserveA.toString(), ethers.utils.parseEther("1000000"))
      assert.equal(reserveB.toString(), ethers.utils.parseEther("1000000"))
    })
  })
  describe("transfer", () => {
    it("sets dividends", async () => {
      await rewards.transfer(deployer.address, deployer.address)
      assert.equal(
        (await prisma.balanceOf(deployer.address)).toString(),
        (
          await rewards.prismaDividendTokenBalanceOf(deployer.address)
        ).toString()
      )
    })
  })
  describe("processDividends", () => {
    it("distributes dividends", async () => {
      await rewards.transfer(deployer.address, deployer.address)
      await rewards.processDividends()
      assert.equal(
        BigInt(await rewards.getTotalPrismaDividendsDistributed()) /
          BigInt(10 ** 18),
        BigInt(1000000)
      )
      assert.equal(
        BigInt(await rewards.withdrawablePrismaDividendOf(deployer.address)) /
          BigInt(10 ** 18),
        BigInt(999999)
      )
    })
    it("corrects dividends", async () => {
      await rewards.transfer(deployer.address, deployer.address)
      await rewards.processDividends()
      await prisma.transfer(user.address, ethers.utils.parseEther("1000000"))
      await rewards.transfer(deployer.address, user.address)
      assert.equal(
        (await rewards.prismaDividendTokenBalanceOf(user.address)).toString(),
        ethers.utils.parseEther("1000000")
      )
      assert.equal(await rewards.withdrawablePrismaDividendOf(user.address), 0)
    })
  })
  describe("claim", () => {
    it("can withdraw dividends", async () => {
      await rewards.transfer(deployer.address, deployer.address)
      await rewards.processDividends()
      const balanceBefore = await busd.balanceOf(deployer.address)
      const dividends = await rewards.withdrawablePrismaDividendOf(
        deployer.address
      )
      await rewards.claim()
      assert(dividends > 0)
      assert.equal(
        BigInt(await busd.balanceOf(deployer.address)) / BigInt(10 ** 18),
        BigInt(balanceBefore) / BigInt(10 ** 18) +
          BigInt(dividends) / BigInt(10 ** 18)
      )
    })
    it("cannot withdraw dividends twice", async () => {
      await rewards.transfer(deployer.address, deployer.address)
      await rewards.processDividends()
      await rewards.claim()
      assert.equal(
        (
          await rewards.withdrawablePrismaDividendOf(deployer.address)
        ).toString(),
        "0"
      )
    })
  })
  describe("processDividendTracker", () => {
    it("processes dividends automatically", async () => {
      await rewards.transfer(deployer.address, deployer.address)
      await rewards.processDividends()
      const balanceBefore = await busd.balanceOf(deployer.address)
      const dividends = await rewards.withdrawablePrismaDividendOf(
        deployer.address
      )
      await rewards.processDividendTracker("1000000")
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
    // it("processes dividends to multiple holders", async () => {
    //   for (let i = 0; i < 1000; i++) {
    //     wallet = ethers.Wallet.createRandom()
    //     wallet = wallet.connect(ethers.provider)
    //     await deployer.sendTransaction({
    //       to: wallet.address,
    //       value: ethers.utils.parseEther("0.5"),
    //     })
    //     await prisma.transfer(wallet.address, ethers.utils.parseEther("100000"))
    //     await rewards.transfer(deployer.address, wallet.address)
    //   }
    //   await rewards.processDividends()
    //   const balanceBefore = await busd.balanceOf(deployer.address)
    //   const dividends = await rewards.withdrawablePrismaDividendOf(
    //     deployer.address
    //   )
    //   await rewards.processDividendTracker("30000000")
    //   assert.equal(
    //     BigInt(await busd.balanceOf(deployer.address)) / BigInt(10 ** 18),
    //     BigInt(balanceBefore) / BigInt(10 ** 18) +
    //       BigInt(dividends) / BigInt(10 ** 18)
    //   )
    // })
  })
})
