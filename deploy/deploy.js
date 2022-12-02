const { getNamedAccounts, deployments, network, ethers } = require("hardhat")
const { verify } = require("../utils/verify")
const { developmentChains } = require("../helper-hardhat-config")

module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy, log } = deployments
  const { deployer } = await getNamedAccounts()

  const prismaToken = await deploy("PrismaToken", {
    from: deployer,
    args: [],
    log: true,
  })
  log(`PrismaToken deployed at ${prismaToken.address}`)

  if (!developmentChains.includes(network.name)) {
    await verify(prismaToken.address)
  }
}

module.exports.tags = ["token", "all"]
