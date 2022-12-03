const { ethers } = require("hardhat")

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

  const wbnb = await deploy("MockWBNBToken", {
    from: deployer.address,
    args: [],
    log: true,
  })
  log(`WBNB deployed at ${wbnb.address}`)

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

  const busd = await deploy("MockBUSDToken", {
    from: deployer.address,
    args: [],
    log: true,
  })
  log(`BUSD deployed at ${busd.address}`)

  const prismaToken = await deploy("PrismaToken", {
    from: deployer.address,
    args: [],
    log: true,
  })
  log(`PrismaToken deployed at ${prismaToken.address}`)
}

module.exports.tags = ["rewards", "all"]
