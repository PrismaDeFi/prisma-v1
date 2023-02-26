const { ethers, upgrades } = require("hardhat")

async function main() {
  const prismaFactory = await ethers.getContractFactory("ALPHA_PrismaToken")
  await upgrades.upgradeProxy(
    "0xB7ED90F0BE22c7942133404474c7c41199C08a2D",
    prismaFactory
  )
  console.log("Box upgraded")
}

main()
