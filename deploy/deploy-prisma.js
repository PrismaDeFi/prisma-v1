const { ethers, upgrades, network } = require("hardhat")
const { verify } = require("../utils/verify")
const { developmentChains } = require("../helper-hardhat-config")

module.exports = async ({ deployments }) => {
  const { deploy, log } = deployments
  const [deployer] = await ethers.getSigners()

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

  const prismaFactory = await ethers.getContractFactory("BETA_PrismaToken")
  const prismaProxy = await upgrades.deployProxy(prismaFactory)
  await prismaProxy.deployed()
  log("PrismaProxy deployed at", prismaProxy.address)

  if (!developmentChains.includes(network.name)) {
    await verify(prismaProxy.address, [])
  }

  const trackerFactory = await ethers.getContractFactory(
    "BETA_PrismaDividendTracker"
  )
  const trackerProxy = await upgrades.deployProxy(trackerFactory)
  await trackerProxy.deployed()
  log("TrackerProxy deployed at", trackerProxy.address)

  if (!developmentChains.includes(network.name)) {
    await verify(trackerProxy.address, [])
  }
}

module.exports.tags = ["prisma", "all"]
