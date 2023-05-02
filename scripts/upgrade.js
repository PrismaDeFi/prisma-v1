const { ethers, upgrades } = require("hardhat")
const { verify } = require("../utils/verify")

async function main() {
  const prismaFactory = await ethers.getContractFactory("ALPHA_PrismaToken")
  const upgradedToken = await upgrades.upgradeProxy(
    "0xB7ED90F0BE22c7942133404474c7c41199C08a2D",
    prismaFactory
  )
  console.log("PrismaToken upgraded")

  await verify(upgradedToken.address, [])
}

main()
