require("@nomicfoundation/hardhat-toolbox")
require("@openzeppelin/hardhat-upgrades")
require("hardhat-deploy")
require("solidity-coverage")
require("hardhat-gas-reporter")
require("keccak256")
require("dotenv").config()

const BSC_RPC_URL = process.env.BSC_RPC_URL
const PRIVATE_KEY = process.env.PRIVATE_KEY
const DEPLOYER_KEY = process.env.DEPLOYER_KEY
const BSCSCAN_API_KEY = process.env.BSCSCAN_API_KEY

module.exports = {
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      chainId: 31337,
      forking: {
        enabled: false,
        url: BSC_RPC_URL,
      },
    },
    localhost: {
      chainId: 31337,
    },
    testnet: {
      url: "https://data-seed-prebsc-1-s1.binance.org:8545",
      gasPrice: 20000000000,
      accounts: [PRIVATE_KEY],
      saveDeployments: true,
      chainId: 97,
    },
    mainnet: {
      url: "https://bsc-dataseed.binance.org/",
      chainId: 56,
      gasPrice: 20000000000,
      accounts: [DEPLOYER_KEY],
    },
  },
  etherscan: {
    apiKey: BSCSCAN_API_KEY,
  },
  gasReporter: {
    enabled: false,
    token: "BNB",
    currency: "USD",
    outputFile: "gas-report.txt",
    gasPrice: 3,
    noColors: true,
    coinmarketcap: process.env.COINMARKETCAP_API_KEY,
  },
  namedAccounts: {
    deployer: {
      default: 0,
      1: 0,
    },
    user1: {
      default: 1,
    },
  },
  solidity: {
    compilers: [
      { version: "0.5.16" },
      {
        version: "0.6.6",
        settings: {
          optimizer: {
            enabled: true,
          },
        },
      },
      {
        version: "0.8.18",
        settings: {
          optimizer: {
            enabled: true,
          },
        },
      },
    ],
  },
  mocha: {
    timeout: 200000,
  },
}
