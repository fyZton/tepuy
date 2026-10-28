import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { network } from "hardhat";
import { ZeroAddress } from "ethers";

const RETRASO_ADMIN_SEG = 86400; // 1 día

const { ethers } = await network.getOrCreate();

const { chainId } = await ethers.provider.getNetwork();
if (chainId !== 31337n) throw new Error(`Solo redes locales (31337), chainId actual: ${chainId}`);

// Cuentas por defecto de Hardhat: 0 desplegador, 1 admin final, 2 emisor, 3 custodio,
// 4 agenteKyc, 5 supervisor, 6 oraculo, 7 recuperador, 8 cuenta de prueba, 9 inversionista B.
const [desplegador, admin, emisor, custodio, agenteKyc, supervisor, oraculo, recuperador, cuentaPrueba, inversionistaB] =
  await ethers.getSigners();
const tepuy = await ethers.deployContract("Tepuy", [RETRASO_ADMIN_SEG, desplegador.address]);
await tepuy.waitForDeployment();

// clave -> [signer, nombre del rol en el contrato]
const roles = {
  emisor: [emisor, "EMISOR"], custodio: [custodio, "CUSTODIO"], agenteKyc: [agenteKyc, "AGENTE_KYC"],
  supervisor: [supervisor, "SUPERVISOR"], oraculo: [oraculo, "ORACULO"], recuperador: [recuperador, "RECUPERADOR"],
} as const;
for (const [signer, nombre] of Object.values(roles)) {
  await (await tepuy.grantRole(await tepuy[nombre](), signer.address)).wait();
}
const verificados = [cuentaPrueba.address, inversionistaB.address];
for (const v of verificados) await (await tepuy.connect(agenteKyc).setVerified(v, true)).wait();
await (await tepuy.connect(emisor).mint(cuentaPrueba.address, 1000)).wait();

await (await tepuy.beginDefaultAdminTransfer(admin.address)).wait();
// El retraso se cumple avanzando el reloj; en red real esto sería esperar.
await ethers.provider.send("evm_increaseTime", [RETRASO_ADMIN_SEG + 1]);
await ethers.provider.send("evm_mine", []);
await (await tepuy.connect(admin).acceptDefaultAdminTransfer()).wait();

if ((await tepuy.defaultAdmin()) !== admin.address) throw new Error("defaultAdmin inesperado");
if ((await tepuy.pendingDefaultAdmin())[0] !== ZeroAddress) throw new Error("Queda un traspaso de admin pendiente");
for (const cuenta of [desplegador, admin, ...Object.values(roles).map(([s]) => s)]) {
  const esperados = [
    ...(cuenta === admin ? [await tepuy.DEFAULT_ADMIN_ROLE()] : []),
    ...(await Promise.all(Object.values(roles).filter(([s]) => s === cuenta).map(([, n]) => tepuy[n]()))),
  ];
  const todos = [await tepuy.DEFAULT_ADMIN_ROLE(), ...(await Promise.all(Object.values(roles).map(([, n]) => tepuy[n]())))];
  for (const rol of todos) {
    if ((await tepuy.hasRole(rol, cuenta.address)) !== esperados.includes(rol)) throw new Error(`Roles inesperados en ${cuenta.address}`);
  }
}

const address = await tepuy.getAddress();
const abi = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function isVerified(address) view returns (bool)",
  "function isFrozen(address) view returns (bool)",
];
writeFileSync(fileURLToPath(new URL("../web/deployment.json", import.meta.url)), JSON.stringify({
  chainId: Number(chainId),
  address,
  verificados,
  roles: { admin: admin.address, ...Object.fromEntries(Object.entries(roles).map(([k, [v]]) => [k, v.address])) },
  abi,
}, null, 2));
console.log(`Tepuy desplegado en ${address}`);
