const { ethers, upgrades } = require("hardhat")
const { verify } = require("../utils/verify")

async function main() {
  const prismaFactory = await ethers.getContractFactory("BETA_PrismaToken")
  const upgradedToken = await upgrades.upgradeProxy(
    "0x96F5dfA892524b865ff0E62964FbD392022C2796",
    prismaFactory
  )
  console.log("PrismaToken upgraded")

  await verify(upgradedToken.address, [])
}

main()
