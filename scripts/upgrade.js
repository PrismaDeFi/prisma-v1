const { ethers, upgrades } = require("hardhat")
const { verify } = require("../utils/verify")

async function main() {
  const prismaFactory = await ethers.getContractFactory("PrismaToken")
  const upgradedToken = await upgrades.upgradeProxy(
    "0x96F5dfA892524b865ff0E62964FbD392022C2796",
    prismaFactory
  )
  console.log("PrismaToken upgraded")

  await verify(upgradedToken.address, [])

  const trackerFactory = await ethers.getContractFactory(
    "PrismaDividendTracker"
  )
  const upgradedTracker = await upgrades.upgradeProxy(
    "0x68298872f80edd8f4325a420D976B279C3850E26",
    trackerFactory
  )
  console.log("PrismaDividendTracker upgraded")

  await verify(upgradedTracker.address, [])
}

main()
