const { ethers, upgrades, network } = require("hardhat")
const { verify } = require("../utils/verify")
const { developmentChains } = require("../helper-hardhat-config")

module.exports = async ({ deployments }) => {
  const { log } = deployments

  const prismaFactory = await ethers.getContractFactory("PrismaToken")
  const prismaProxy = await upgrades.deployProxy(prismaFactory)
  await prismaProxy.deployed()
  log("PrismaProxy deployed at", prismaProxy.address)

  if (!developmentChains.includes(network.name)) {
    await verify(prismaProxy.address, [])
  }

  const trackerFactory = await ethers.getContractFactory(
    "PrismaDividendTracker"
  )
  const trackerProxy = await upgrades.deployProxy(trackerFactory)
  await trackerProxy.deployed()
  log("TrackerProxy deployed at", trackerProxy.address)

  if (!developmentChains.includes(network.name)) {
    await verify(trackerProxy.address, [])
  }
}

module.exports.tags = ["prisma", "all"]
