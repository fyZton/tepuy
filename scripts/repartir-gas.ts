// Reparte ETH de prueba desde el desplegador a las cuentas que firman, para pedir faucet una sola vez.
// Uso: CONFIRM_DEPLOY=yes npx hardhat run scripts/repartir-gas.ts --network arbitrumSepolia
import { network } from "hardhat";

const MONTO = "0.004";
const MINIMO = "0.002";
const NOMBRES = ["desplegador", "admin", "emisor", "custodio", "agenteKyc", "supervisor", "oraculo", "recuperador", "inversionistaA", "inversionistaB"];

const { ethers } = await network.getOrCreate();
const { chainId } = await ethers.provider.getNetwork();
if (![421614n, 11155111n].includes(chainId)) throw new Error(`Solo testnets públicas (421614, 11155111), chainId: ${chainId}`);

const [desplegador, ...resto] = await ethers.getSigners();
const monto = ethers.parseEther(MONTO);
const minimo = ethers.parseEther(MINIMO);
const pendientes = [];
for (const [i, s] of resto.entries()) {
  const saldo = await ethers.provider.getBalance(s.address);
  if (saldo < minimo) pendientes.push(s);
  console.log(`${NOMBRES[i + 1].padEnd(15)} ${s.address}  ${ethers.formatEther(saldo)} ETH${saldo < minimo ? "  -> recibirá " + MONTO : ""}`);
}
const total = monto * BigInt(pendientes.length);
const disponible = await ethers.provider.getBalance(desplegador.address);
console.log(`Desplegador ${desplegador.address}: ${ethers.formatEther(disponible)} ETH; a repartir: ${ethers.formatEther(total)} ETH`);
if (pendientes.length === 0) process.exit(0);
if (disponible < total + monto) throw new Error("El desplegador no tiene ETH suficiente para repartir y desplegar");
if (process.env.CONFIRM_DEPLOY !== "yes") {
  console.log("Plan: no se envió nada. Para repartir: CONFIRM_DEPLOY=yes");
  process.exit(0);
}
for (const s of pendientes) await (await desplegador.sendTransaction({ to: s.address, value: monto })).wait();
console.log(`Listo: ${pendientes.length} cuentas recibieron ${MONTO} ETH cada una.`);
