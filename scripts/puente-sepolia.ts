// Pasa el ETH de prueba del desplegador de Ethereum Sepolia a Arbitrum Sepolia (para faucets que solo dan Sepolia).
// Uso: SEPOLIA_RPC=... CONFIRM_DEPLOY=yes npx hardhat run scripts/puente-sepolia.ts --network sepolia
import { network } from "hardhat";

const INBOX = "0xaAe29B0366299461418F5324a79Afc425BE5ae21"; // Delayed Inbox de Arbitrum Sepolia en Sepolia (docs.arbitrum.io)
const RESERVA = "0.002"; // queda en Sepolia para pagar el gas de esta transacción

const { ethers } = await network.getOrCreate();
const { chainId } = await ethers.provider.getNetwork();
if (chainId !== 11155111n) throw new Error(`Solo Ethereum Sepolia (11155111), chainId: ${chainId}`);

const [desplegador] = await ethers.getSigners();
const saldo = await ethers.provider.getBalance(desplegador.address);
const monto = saldo - ethers.parseEther(RESERVA);
console.log(`Desplegador ${desplegador.address}: ${ethers.formatEther(saldo)} ETH en Sepolia`);
if (monto <= 0n) throw new Error(`Saldo insuficiente: hace falta más de ${RESERVA} ETH`);
if (process.env.CONFIRM_DEPLOY !== "yes") {
  console.log(`Plan: enviar ${ethers.formatEther(monto)} ETH a Arbitrum Sepolia. No se envió nada. Para enviar: CONFIRM_DEPLOY=yes`);
  process.exit(0);
}
const inbox = new ethers.Contract(INBOX, ["function depositEth() payable returns (uint256)"], desplegador);
const tx = await inbox.depositEth({ value: monto });
await tx.wait();
console.log(`Enviado: ${ethers.formatEther(monto)} ETH. Tx ${tx.hash}. Llega a Arbitrum Sepolia en ~10-15 min.`);
