const { assert, expect } = require("chai")
const { deployments, ethers } = require("hardhat")

const INITIAL_BUSD_LIQUIDITY = ethers.utils.parseEther("57000")
const INITIAL_PRISMA_LIQUIDITY = ethers.utils.parseEther("58000000")

describe("PrismaV1 Test", () => {
  let prismaToken,
    tracker,
    wbnb,
    busd,
    deployer,
    user,
    multisig,
    liquidity,
    treasury
  beforeEach(async () => {
    ;[deployer, user, multisig, liquidity, treasury] = await ethers.getSigners()

    await deployments.fixture("all")

    prismaToken = await ethers.getContract("PrismaToken", deployer)
    tracker = await ethers.getContract("PrismaDividendTracker", deployer)
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
    await prismaMultisig.init(busd.address, tracker.address)
    await prismaMultisig.transfer(
      deployer.address,
      ethers.utils.parseEther("100000000")
    )
    await prismaMultisig.transfer(
      this.router.address,
      ethers.utils.parseEther("1000000")
    )
    await prismaMultisig.transferOwnership(deployer.address)

    await tracker.init(busd.address, this.router.address, prismaToken.address)
    const pairAddress = await this.factory.getPair(
      prismaToken.address,
      busd.address
    )
    this.pair = await ethers.getContractAt("IUniswapV2Pair", pairAddress)
    await tracker.excludeFromDividends(pairAddress)
    await tracker.transferOwnership(prismaToken.address)

    await busd.transfer(prismaToken.address, ethers.utils.parseEther("1000"))

    await prismaToken.approve(this.router.address, INITIAL_PRISMA_LIQUIDITY)
    await busd.approve(this.router.address, INITIAL_BUSD_LIQUIDITY)
    await this.router.addLiquidity(
      prismaToken.address,
      busd.address,
      INITIAL_PRISMA_LIQUIDITY,
      INITIAL_BUSD_LIQUIDITY,
      0,
      0,
      deployer.address,
      (await ethers.provider.getBlock()).timestamp + 100
    )

    await prismaToken.setAutomatedMarketPair(pairAddress, true)
  })
  describe("init", () => {
    it("initialized correctly", async () => {
      const name = await prismaToken.name()
      const symbol = await prismaToken.symbol()
      assert.equal(name.toString(), "Prisma Finance")
      assert.equal(symbol.toString(), "PRISMA")
      assert.equal(
        (await prismaToken.totalSupply()).toString(),
        ethers.utils.parseEther("100000000")
      )
    })
    it("cannot be reinizialized", async () => {
      await expect(
        prismaToken.init(busd.address, tracker.address)
      ).to.be.revertedWith("Initializable: contract is already initialized")
    })
    it("has liquidity", async () => {
      const [reserveA, reserveB] = await this.pair.getReserves()
      assert.equal(reserveA.toString(), INITIAL_BUSD_LIQUIDITY)
      assert.equal(reserveB.toString(), INITIAL_PRISMA_LIQUIDITY)
    })
  })
  describe("_transferFrom", () => {
    it("buy orders are taxed correctly", async () => {
      const amountIn = ethers.utils.parseEther("10000")
      const path = [busd.address, prismaToken.address]
      await busd.approve(this.router.address, amountIn)
      const prismaBalanceBefore = await prismaToken.balanceOf(deployer.address)
      const busdBalanceBefore = await busd.balanceOf(deployer.address)
      const [, amountOutB] = await this.router.getAmountsOut(amountIn, path)
      await this.router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
        amountIn,
        0,
        path,
        deployer.address,
        (await ethers.provider.getBlock()).timestamp + 100
      )
      const prismaBalanceAfter = await prismaToken.balanceOf(deployer.address)
      const busdBalanceAfter = await busd.balanceOf(deployer.address)
      const buyFee = await prismaToken.getTotalBuyFees()
      const taxedAmountOut =
        (BigInt(100 - buyFee) * BigInt(amountOutB)) / BigInt(100)
      assert.equal(
        BigInt(prismaBalanceAfter) / BigInt(10 ** 18),
        BigInt(prismaBalanceBefore) / BigInt(10 ** 18) +
          BigInt(taxedAmountOut) / BigInt(10 ** 18)
      )
      assert.equal(
        BigInt(busdBalanceAfter) / BigInt(10 ** 18),
        BigInt(busdBalanceBefore) / BigInt(10 ** 18) -
          BigInt(amountIn) / BigInt(10 ** 18)
      )
    })
    it("sell orders are taxed correctly", async () => {
      const amountIn = ethers.utils.parseEther("10000")
      const path = [prismaToken.address, busd.address]
      await prismaToken.approve(this.router.address, amountIn)
      const prismaBalanceBefore = await prismaToken.balanceOf(deployer.address)
      const busdBalanceBefore = await busd.balanceOf(deployer.address)
      const sellFee = await prismaToken.getTotalSellFees()
      const taxedAmountIn =
        (BigInt(100 - sellFee) * BigInt(amountIn)) / BigInt(100)
      const [, amountOutB] = await this.router.getAmountsOut(
        taxedAmountIn,
        path
      )
      await this.router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
        amountIn,
        0,
        path,
        deployer.address,
        (await ethers.provider.getBlock()).timestamp + 100
      )
      const prismaBalanceAfter = await prismaToken.balanceOf(deployer.address)
      const busdBalanceAfter = await busd.balanceOf(deployer.address)
      assert.equal(
        BigInt(busdBalanceAfter) / BigInt(10 ** 18),
        BigInt(busdBalanceBefore) / BigInt(10 ** 18) +
          BigInt(amountOutB) / BigInt(10 ** 18)
      )
      assert.equal(
        BigInt(prismaBalanceAfter) / BigInt(10 ** 18),
        BigInt(prismaBalanceBefore) / BigInt(10 ** 18) -
          BigInt(amountIn) / BigInt(10 ** 18)
      )
    })
    it("normal transfers are not taxed", async () => {
      await prismaToken.transfer(user.address, ethers.utils.parseEther("10000"))
      const userBalance = await prismaToken.balanceOf(user.address)
      assert.equal(userBalance.toString(), ethers.utils.parseEther("10000"))
    })
    it("cannot sell staked balance", async () => {
      await prismaToken.transfer(user.address, ethers.utils.parseEther("10000"))
      const prismaUser = prismaToken.connect(user)
      await prismaUser.stakePrisma(ethers.utils.parseEther("5000"))
      await expect(
        prismaUser.transfer(
          this.router.address,
          ethers.utils.parseEther("7500")
        )
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
  describe("setBalance", () => {
    it("sets dividends", async () => {
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
      await prismaToken.processDividends()
      assert.equal(
        BigInt(await prismaToken.getTotalPrismaDividendsDistributed()) /
          BigInt(10 ** 18),
        BigInt(1000)
      )
      assert.equal(
        BigInt(
          await prismaToken.withdrawablePrismaDividendOf(deployer.address)
        ) / BigInt(10 ** 18),
        BigInt(999)
      )
    })
    it("corrects dividends", async () => {
      await prismaToken.processDividends()
      await prismaToken.transfer(
        user.address,
        ethers.utils.parseEther("1000000")
      )
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
      await prismaToken.processDividends()
      const balanceBefore = await busd.balanceOf(deployer.address)
      const dividends = await prismaToken.withdrawablePrismaDividendOf(
        deployer.address
      )
      await prismaToken.claim(ethers.utils.parseEther("999"))
      assert(dividends > 0)
      assert.equal(
        BigInt(await busd.balanceOf(deployer.address)) / BigInt(10 ** 18),
        BigInt(balanceBefore) / BigInt(10 ** 18) +
          BigInt(dividends) / BigInt(10 ** 18)
      )
    })
    it("can reinvest all dividends", async () => {
      await prismaToken.stakePrisma(ethers.utils.parseEther("21000000"))
      const busdDividends = await busd.balanceOf(prismaToken.address)
      const stakedBefore = await prismaToken.getTotalStakedAmount()
      const totalStake = await prismaToken.getTotalStakedAmount()
      const totalPrisma = await tracker.totalSupply()
      const amountIn =
        (BigInt(busdDividends) *
          ((BigInt(totalStake) * BigInt(2 ** 128)) / BigInt(totalPrisma))) /
        BigInt(2 ** 128)
      const path = [busd.address, prismaToken.address]
      const [, amountOutB] = await this.router.getAmountsOut(amountIn, path)
      await prismaToken.processDividends()
      const stakedAfter = await prismaToken.getTotalStakedAmount()
      const busdBalanceAfter = await busd.balanceOf(tracker.address)
      assert.equal(
        BigInt(stakedAfter) / BigInt(10 ** 18),
        BigInt(stakedBefore) / BigInt(10 ** 18) +
          BigInt(amountOutB) / BigInt(10 ** 18)
      )
      assert.equal(
        BigInt(busdBalanceAfter),
        BigInt(busdDividends) - BigInt(amountIn)
      )
    })
    it("cannot withdraw dividends twice", async () => {
      await prismaToken.processDividends()
      await prismaToken.claim(ethers.utils.parseEther("999"))
      assert.equal(
        BigInt(await tracker.withdrawableDividendOf(deployer.address)) /
          BigInt(10 ** 18),
        0n
      )
    })
  })
  describe("manualReinvest", () => {
    it("processes arbitrary amount dividends manually", async () => {
      await prismaToken.processDividends()
      await prismaToken.stakePrisma(ethers.utils.parseEther("21000000"))
      const balanceBefore = await prismaToken.balanceOf(deployer.address)
      const stakedBefore = await prismaToken.getStakedPrisma(deployer.address)
      const dividendsBefore = await prismaToken.withdrawablePrismaDividendOf(
        deployer.address
      )
      const amountIn = ethers.utils.parseEther("500")
      const path = [busd.address, prismaToken.address]
      const [, amountOutB] = await this.router.getAmountsOut(amountIn, path)
      await tracker.manualReinvest(amountIn)
      const balanceAfter = await prismaToken.balanceOf(deployer.address)
      const stakedAfter = await prismaToken.getStakedPrisma(deployer.address)
      const dividendsAfter = await prismaToken.withdrawablePrismaDividendOf(
        deployer.address
      )
      assert.equal(
        BigInt(balanceAfter),
        BigInt(balanceBefore) + BigInt(amountOutB)
      )
      assert.equal(
        BigInt(stakedAfter),
        BigInt(stakedBefore) + BigInt(amountOutB)
      )
      assert.equal(
        BigInt(dividendsAfter),
        BigInt(dividendsBefore) - BigInt(amountIn)
      )
    })
  })
  describe("processDividendTracker", () => {
    it("processes dividends automatically", async () => {
      await prismaToken.processDividends()
      const balanceBefore = await busd.balanceOf(deployer.address)
      const dividends = await prismaToken.withdrawablePrismaDividendOf(
        deployer.address
      )
      await prismaToken.processDividendTracker("1000000", false)
      assert(dividends > 0)
      assert.equal(
        BigInt(await busd.balanceOf(deployer.address)) / BigInt(10 ** 18),
        BigInt(balanceBefore) / BigInt(10 ** 18) +
          BigInt(dividends) / BigInt(10 ** 18)
      )
    })
    it("processes reinvestment automatically", async () => {
      await prismaToken.stakePrisma(ethers.utils.parseEther("21000000"))
      const balanceBefore = await prismaToken.balanceOf(deployer.address)
      const stakedBefore = await prismaToken.getStakedPrisma(deployer.address)
      const busdDividends = await busd.balanceOf(prismaToken.address)
      const prismaInTracker = await prismaToken.balanceOf(tracker.address)
      const totalStake = await prismaToken.getTotalStakedAmount()
      const totalPrisma = await tracker.totalSupply()
      const amountIn =
        (BigInt(busdDividends) *
          ((BigInt(totalStake) * BigInt(2 ** 128)) / BigInt(totalPrisma))) /
        BigInt(2 ** 128)
      const path = [busd.address, prismaToken.address]
      const [, amountOutB] = await this.router.getAmountsOut(amountIn, path)
      const prismaPerShare =
        ((BigInt(amountOutB) + BigInt(prismaInTracker)) * BigInt(2 ** 128)) /
        BigInt(totalStake)
      const prismaDividend =
        (BigInt(prismaPerShare) * BigInt(stakedBefore)) / BigInt(2 ** 128)
      await prismaToken.processDividends()
      const balanceAfter = await prismaToken.balanceOf(deployer.address)
      const stakedAfter = await prismaToken.getStakedPrisma(deployer.address)
      assert.equal(
        BigInt(balanceAfter),
        BigInt(balanceBefore) + BigInt(prismaDividend)
      )
      assert.equal(
        BigInt(stakedAfter),
        BigInt(stakedBefore) + BigInt(prismaDividend)
      )
    })
    ///////////////////////////////////////
    // Uncomment to fry your motherboard //
    ///////////////////////////////////////
    // it("processes dividends for multiple holders", async () => {
    //   for (let i = 0; i < 100; i++) {
    //     wallet = ethers.Wallet.createRandom()
    //     wallet = wallet.connect(ethers.provider)
    //     await deployer.sendTransaction({
    //       to: wallet.address,
    //       value: ethers.utils.parseEther("1"),
    //     })
    //     await prismaToken.transfer(
    //       wallet.address,
    //       ethers.utils.parseEther("10000")
    //     )
    //   }
    //   await prismaToken.processDividends()
    //   const balanceBefore = await busd.balanceOf(deployer.address)
    //   const dividends = await prismaToken.withdrawablePrismaDividendOf(
    //     deployer.address
    //   )
    //   await prismaToken.processDividendTracker("30000000", false)
    //   assert.equal(
    //     BigInt(await busd.balanceOf(deployer.address)) / BigInt(10 ** 18),
    //     BigInt(balanceBefore) / BigInt(10 ** 18) +
    //       BigInt(dividends) / BigInt(10 ** 18)
    //   )
    // })
    // it("reinvests dividends for multiple holders", async () => {
    //   for (let i = 0; i < 100; i++) {
    //     wallet = ethers.Wallet.createRandom()
    //     wallet = wallet.connect(ethers.provider)
    //     prismaUser = prismaToken.connect(wallet)
    //     await prismaToken.transfer(
    //       wallet.address,
    //       ethers.utils.parseEther("10000")
    //     )
    //     await deployer.sendTransaction({
    //       to: wallet.address,
    //       value: ethers.utils.parseEther("1"),
    //     })
    //     await prismaUser.stakePrisma(ethers.utils.parseEther("5000"))
    //   }
    //   const busdDividends = await busd.balanceOf(prismaToken.address)
    //   const totalStakeBefore = await prismaToken.getTotalStakedAmount()
    //   const totalPrisma = await tracker.totalSupply()
    //   const amountIn =
    //     (BigInt(busdDividends) *
    //       ((BigInt(totalStakeBefore) * BigInt(2 ** 128)) /
    //         BigInt(totalPrisma))) /
    //     BigInt(2 ** 128)
    //   const path = [busd.address, prismaToken.address]
    //   const [, amountOutB] = await this.router.getAmountsOut(amountIn, path)
    //   await prismaToken.processDividends()
    //   const totalStakeAfter = await prismaToken.getTotalStakedAmount()
    //   assert.equal(
    //     BigInt(totalStakeAfter) / BigInt(10 ** 18),
    //     BigInt(totalStakeBefore) / BigInt(10 ** 18) +
    //       BigInt(amountOutB) / BigInt(10 ** 18)
    //   )
    // })
  })
})
