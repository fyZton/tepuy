import hardhatToolboxMochaEthers from "@nomicfoundation/hardhat-toolbox-mocha-ethers";
import { defineConfig } from "hardhat/config";

// Una clave por rol, en este orden (deploy.ts depende de él). Solo variables de entorno: nada de claves en el repo.
const ROLES_CLAVES = ["DESPLEGADOR", "ADMIN", "EMISOR", "CUSTODIO", "KYC", "SUPERVISOR", "ORACULO", "RECUPERADOR"];
const DEMO_CLAVES = ["INVERSIONISTA_A", "INVERSIONISTA_B"]; // opcionales: sin ellas se omiten los pasos demo
const env = (n: string): string => (process.env[`TEPUY_KEY_${n}`] ?? "").trim();
// Si falta cualquier clave de rol no se configura ninguna (el orden importa); deploy.ts lo explica. La config nunca falla por esto.
// Una clave con formato inválido cuenta como ausente: Hardhat abortaría toda la config (npm test incluido) sin nombrar la variable.
const valida = (n: string): boolean => /^0x[0-9a-fA-F]{64}$/.test(env(n));
const cuentas = (): string[] =>
  ROLES_CLAVES.every(valida) ? [...ROLES_CLAVES, ...(DEMO_CLAVES.every(valida) ? DEMO_CLAVES : [])].map(env) : [];
// ponytail: sin configVariable de Hardhat (lanza si falta la variable y exige keystore para el resto); env directo basta.
const publica = (chainId: number, rpc: string) =>
  ({ type: "http", chainId, url: process.env[rpc] || "http://127.0.0.1:1" /* inerte: solo se usa si eliges esta red */, accounts: cuentas() }) as const;

export default defineConfig({
  networks: {
    localhost: { type: "http", url: process.env.TEPUY_RPC ?? "http://127.0.0.1:8545" },
    arbitrumSepolia: publica(421614, "ARBITRUM_SEPOLIA_RPC"),
    sepolia: publica(11155111, "SEPOLIA_RPC"),
    // Solo pruebas: red en proceso con el chainId de Arbitrum Sepolia (no toca ninguna red real).
    simArbitrum: { type: "edr-simulated", chainId: 421614 },
    simAjena: { type: "edr-simulated", chainId: 1 }, // para probar que deploy.ts rechaza chainIds no previstos
  },
  plugins: [hardhatToolboxMochaEthers],
  solidity: {
    version: "0.8.28",
    settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: "cancun" },
  },
  test: {
    solidity: { fuzz: { runs: 1000 }, invariant: { runs: 256, depth: 64, failOnRevert: false } },
  },
});
