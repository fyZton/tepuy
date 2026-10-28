import hardhatToolboxMochaEthers from "@nomicfoundation/hardhat-toolbox-mocha-ethers";
import { defineConfig } from "hardhat/config";

export default defineConfig({
  networks: { localhost: { type: "http", url: process.env.TEPUY_RPC ?? "http://127.0.0.1:8545" } },
  plugins: [hardhatToolboxMochaEthers],
  solidity: {
    version: "0.8.28",
    settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: "cancun" },
  },
  test: {
    solidity: { fuzz: { runs: 1000 }, invariant: { runs: 256, depth: 64, failOnRevert: false } },
  },
});
