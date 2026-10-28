import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { network } from "hardhat";

const RETRASO_ADMIN_SEG = 86400; // 1 día

const { ethers } = await network.getOrCreate();

const { chainId } = await ethers.provider.getNetwork();
if (chainId !== 31337n) throw new Error(`Solo redes locales (31337), chainId actual: ${chainId}`);

const [admin, emisor, cuentaPrueba] = await ethers.getSigners();
const tepuy = await ethers.deployContract("Tepuy", [RETRASO_ADMIN_SEG, admin.address]);
await tepuy.waitForDeployment();

await (await tepuy.grantRole(await tepuy.EMISOR(), emisor.address)).wait();
await (await tepuy.connect(emisor).mint(cuentaPrueba.address, 1000)).wait();

const address = await tepuy.getAddress();
const abi = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
];
writeFileSync(fileURLToPath(new URL("../web/deployment.json", import.meta.url)), JSON.stringify({ chainId: Number(chainId), address, abi }, null, 2));
console.log(`Tepuy desplegado en ${address}`);
