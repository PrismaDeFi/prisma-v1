const { ethers, upgrades, network } = require("hardhat")
const { verify } = require("../utils/verify")
const { developmentChains } = require("../helper-hardhat-config")

module.exports = async ({ deployments }) => {
  const { deploy, log } = deployments
  const [deployer] = await ethers.getSigners()

  const prismaCharity = await deploy("PrismaCharity", {
    from: deployer.address,
    args: [],
    log: true,
  })
  log(`PrismaCharity deployed at ${prismaCharity.address}`)

  if (!developmentChains.includes(network.name)) {
    await verify(prismaCharity.address, [])
  }
}

module.exports.tags = ["charity", "all"]
