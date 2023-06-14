const { ethers, upgrades } = require("hardhat")
const { verify } = require("../utils/verify")

async function main() {
  const prismaFactory = await ethers.getContractFactory("PrismaToken")
  const upgradedToken = await upgrades.upgradeProxy(
    "0x4bE042c0C69D809B8D739369515A1Ee7d4DFFBc7",
    prismaFactory
  )
  console.log("PrismaToken upgraded")

  await verify(upgradedToken.address, [])

  // const trackerFactory = await ethers.getContractFactory(
  //   "PrismaDividendTracker"
  // )
  // const upgradedTracker = await upgrades.upgradeProxy(
  //   "0x68298872f80edd8f4325a420D976B279C3850E26",
  //   trackerFactory
  // )
  // console.log("PrismaDividendTracker upgraded")

  // await verify(upgradedTracker.address, [])
}

main()
