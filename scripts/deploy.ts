import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
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
// El custodio atestigua antes de que el emisor pueda acuñar.
await (await tepuy.connect(custodio).setAttestedShares(10000)).wait();
await (await tepuy.connect(emisor).mint(cuentaPrueba.address, 1000)).wait();
// Fecha de registro de demo (snapshot #1), tras acuñar.
await (await tepuy.connect(emisor).snapshot()).wait();

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

// Precio de demo: línea "R|" de MVZ.A y fecha de "IG|DDMMAAAA|" del archivo oficial (bytes; latin-1), SHA-256 del archivo completo.
const archivo = readFileSync(fileURLToPath(new URL("../oraculo/tests/fixtures/20261027.dat", import.meta.url)));
const lineas = archivo.toString("latin1").split(/\r?\n/).map((l) => l.trim());
const linea = lineas.find((l) => l.startsWith("R|") && l.split("|")[2] === "MVZ.A");
const ig = lineas.find((l) => l.startsWith("IG|"))?.split("|")[1] ?? "";
if (!/^[0-9]{8}$/.test(ig)) throw new Error("Falta la línea IG|DDMMAAAA| en el fixture");
const fecha = Number(ig.slice(4) + ig.slice(2, 4) + ig.slice(0, 2));
if (!linea) throw new Error("MVZ.A no está en el fixture");
const [ent, dec = ""] = linea.split("|")[4].split("."); // decimales por texto, sin float
if (!/^[0-9]+$/.test(ent) || !/^[0-9]{0,2}$/.test(dec)) throw new Error(`Cierre inválido: ${linea}`);
const centimos = BigInt(ent + dec.padEnd(2, "0"));
await (await tepuy.connect(oraculo).publishPrice(centimos, fecha,"0x" + createHash("sha256").update(archivo).digest("hex"))).wait();

const address = await tepuy.getAddress();
const abi = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function isVerified(address) view returns (bool)",
  "function isFrozen(address) view returns (bool)",
  "function accionesAtestiguadas() view returns (uint256)",
  "function paused() view returns (bool)",
  "function snapshot() returns (uint256)",
  "function snapshotCount() view returns (uint256)",
  "function snapshotBlock(uint256) view returns (uint48)",
  "function balanceOfAt(address, uint256) view returns (uint256)",
  "function totalSupplyAt(uint256) view returns (uint256)",
  "event SnapshotCreado(uint256 indexed id, uint48 bloque, address indexed emisor)",
  "function ultimoPrecio() view returns (uint256 centimos, bytes32 sha256Archivo, uint32 fecha, uint64 publicadoEn)",
  "event PrecioPublicado(uint32 indexed fecha, uint256 centimos, bytes32 sha256Archivo, address indexed oraculo)",
  "event TransferenciaForzada(address indexed from, address indexed to, uint256 amount, string motivo, address indexed recuperador)",
  "event CuentaRecuperada(address indexed perdida, address indexed nueva, uint256 saldo, string motivo, address indexed recuperador)",
];
writeFileSync(fileURLToPath(new URL("../web/deployment.json", import.meta.url)), JSON.stringify({
  chainId: Number(chainId),
  address,
  verificados,
  roles: { admin: admin.address, ...Object.fromEntries(Object.entries(roles).map(([k, [v]]) => [k, v.address])) },
  abi,
}, null, 2));
console.log(`Tepuy desplegado en ${address}`);
