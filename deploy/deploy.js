const { ethers, upgrades, network } = require("hardhat")
const { verify } = require("../utils/verify")
const { developmentChains } = require("../helper-hardhat-config")

module.exports = async ({ deployments }) => {
  const { deploy, log } = deployments
  const [deployer] = await ethers.getSigners()

  const factoryAbi = require("@uniswap/v2-core/build/UniswapV2Factory.json").abi
  const factoryBytecode =
    require("@uniswap/v2-core/build/UniswapV2Factory.json").bytecode
  const factoryFactory = new ethers.ContractFactory(
    factoryAbi,
    factoryBytecode,
    deployer
  )
  const factory = await factoryFactory.deploy(deployer.address)
  await factory.deployTransaction.wait()
  log(`UniswapV2Factory deployed at ${factory.address}`)

  // if (!developmentChains.includes(network.name)) {
  //   await verify(factory.address, [deployer.address])
  // }

  const wbnb = await deploy("MockWBNBToken", {
    from: deployer.address,
    args: [],
    log: true,
  })
  log(`WBNB deployed at ${wbnb.address}`)

  // if (!developmentChains.includes(network.name)) {
  //   await verify(wbnb.address, [])
  // }

  const routerAbi =
    require("@uniswap/v2-periphery/build/UniswapV2Router02.json").abi
  const routerBytecode =
    require("@uniswap/v2-periphery/build/UniswapV2Router02.json").bytecode
  const routerFactory = new ethers.ContractFactory(
    routerAbi,
    routerBytecode,
    deployer
  )
  const router = await routerFactory.deploy(factory.address, wbnb.address)
  await router.deployTransaction.wait()
  log(`UniswapV2Router deployed at ${router.address}`)

  // if (!developmentChains.includes(network.name)) {
  //   await verify(router.address, [factory.address, wbnb.address])
  // }

  const busd = await deploy("MockBUSDToken", {
    from: deployer.address,
    args: [],
    log: true,
  })
  log(`BUSD deployed at ${busd.address}`)

  // if (!developmentChains.includes(network.name)) {
  //   await verify(busd.address, [])
  // }

  // const prismaToken = await deploy("PrismaToken", {
  //   from: deployer.address,
  //   args: [],
  //   log: true,
  // })
  // log(`PrismaToken deployed at ${prismaToken.address}`)

  // if (!developmentChains.includes(network.name)) {
  //   await verify(prismaToken.address)
  // }

  // const prismaDividendTracker = await deploy("PrismaDividendTracker", {
  //   from: deployer.address,
  //   args: [],
  //   log: true,
  // })
  // log(`PrismaDividendTracker deployed at ${prismaDividendTracker.address}`)

  // if (!developmentChains.includes(network.name)) {
  //   await verify(prismaDividendTracker.address)
  // }

  const prismaFactory = await ethers.getContractFactory("ALPHA_PrismaToken")
  const prismaProxy = await upgrades.deployProxy(prismaFactory)
  await prismaProxy.deployed()
  log("PrismaProxy deployed at", prismaProxy.address)

  if (!developmentChains.includes(network.name)) {
    await verify(prismaProxy.address, [])
  }

  const trackerFactory = await ethers.getContractFactory(
    "ALPHA_PrismaDividendTracker"
  )
  const trackerProxy = await upgrades.deployProxy(trackerFactory)
  await trackerProxy.deployed()
  log("TrackerProxy deployed at", trackerProxy.address)

  if (!developmentChains.includes(network.name)) {
    await verify(trackerProxy.address, [])
  }

  // const prismaAdmin = await deploy("PrismaAdmin", {
  //   from: deployer.address,
  //   args: [],
  //   log: true,
  // })
  // log(`PrismaAdmin deployed at ${prismaAdmin.address}`)

  // if (!developmentChains.includes(network.name)) {
  //   await verify(prismaAdmin.address)
  // }

  // const prismaProxy = await deploy("PrismaProxy", {
  //   from: deployer.address,
  //   args: [
  //     prismaToken.address,
  //     prismaAdmin.address,
  //     ethers.utils.formatBytes32String(""),
  //   ],
  //   log: true,
  // })
  // log(`PrismaProxy deployed at ${prismaProxy.address}`)

  // if (!developmentChains.includes(network.name)) {
  //   await verify(prismaProxy.address, [
  //     prismaToken.address,
  //     prismaAdmin.address,
  //   ])
  // }

  // const trackerProxy = await deploy("PrismaProxy", {
  //   from: deployer.address,
  //   args: [
  //     prismaDividendTracker.address,
  //     prismaAdmin.address,
  //     ethers.utils.formatBytes32String(""),
  //   ],
  //   log: true,
  // })
  // log(`TrackerProxy deployed at ${trackerProxy.address}`)

  // if (!developmentChains.includes(network.name)) {
  //   await verify(trackerProxy.address, [
  //     prismaDividendTracker.address,
  //     prismaAdmin.address,
  //   ])
  // }
}

module.exports.tags = ["rewards", "all"]
