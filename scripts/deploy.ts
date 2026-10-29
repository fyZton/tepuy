import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { network } from "hardhat";
import { verificarRoles } from "./verificar-roles.ts";

const RETRASO_ADMIN_SEG = 86400; // 1 día

const { ethers, networkConfig, networkName } = await network.getOrCreate();

const { chainId } = await ethers.provider.getNetwork();
const local = chainId === 31337n;
if (!local && ![421614n, 11155111n].includes(chainId)) throw new Error(`chainId no permitido: ${chainId} (solo 31337, 421614 y 11155111)`);
const simulada = networkConfig.type === "edr-simulated"; // en proceso: se puede avanzar el reloj

// Cuentas por defecto de Hardhat: 0 desplegador, 1 admin final, 2 emisor, 3 custodio,
// 4 agenteKyc, 5 supervisor, 6 oraculo, 7 recuperador, 8 cuenta de prueba, 9 inversionista B.
const [desplegador, admin, emisor, custodio, agenteKyc, supervisor, oraculo, recuperador, cuentaPrueba, inversionistaB] =
  await ethers.getSigners();
const demo = local || cuentaPrueba !== undefined && inversionistaB !== undefined; // sin inversionistas se omiten los pasos demo

if (!local) {
  // Red pública (o simulada con su chainId): sin CONFIRM_DEPLOY solo se imprime el plan y no se envía nada.
  const confirmado = process.env.CONFIRM_DEPLOY === "yes";
  const cuentas = [["desplegador", desplegador], ["admin", admin], ["emisor", emisor], ["custodio", custodio], ["agenteKyc", agenteKyc],
    ["supervisor", supervisor], ["oraculo", oraculo], ["recuperador", recuperador],
    ...(demo ? [["inversionistaA", cuentaPrueba], ["inversionistaB", inversionistaB]] : [])] as const;
  const problemas: string[] = [];
  console.log(`Red: ${networkName}  chainId: ${chainId}${simulada ? "  (simulada en proceso)" : ""}`);
  if (desplegador === undefined || recuperador === undefined) {
    // Solo nombres de variables, nunca valores.
    for (const n of ["DESPLEGADOR", "ADMIN", "EMISOR", "CUSTODIO", "KYC", "SUPERVISOR", "ORACULO", "RECUPERADOR"]) {
      const v = (process.env[`TEPUY_KEY_${n}`] ?? "").trim();
      if (!/^0x[0-9a-fA-F]{64}$/.test(v)) problemas.push(`TEPUY_KEY_${n} ${v ? "no tiene formato 0x + 64 hex" : "no está definida"} (ver .env.example)`);
    }
  } else {
    if (new Set(cuentas.map(([, s]) => s.address)).size !== cuentas.length) problemas.push("Cada rol necesita una cuenta distinta (hay direcciones repetidas)");
    for (const [rol, s] of cuentas) {
      const saldo = await ethers.provider.getBalance(s.address);
      console.log(`  ${rol.padEnd(15)} ${s.address}  ${ethers.formatEther(saldo)} ETH`);
      if (saldo === 0n && !["supervisor", "recuperador", "inversionistaA", "inversionistaB"].includes(rol)) problemas.push(`${rol} no tiene gas`);
    }
    if (!demo) console.log("Aviso: sin TEPUY_KEY_INVERSIONISTA_A/B se omiten los pasos demo (KYC, acuñación, snapshot, dividendo).");
    console.log(`Haría: desplegar Tepuy (retraso admin ${RETRASO_ADMIN_SEG} s), otorgar 6 roles, publicar el precio${demo ? ", pasos demo" : ""}, `
      + `iniciar el traspaso del admin${simulada ? " y aceptarlo (reloj simulado)" : " (aceptarlo tras 24 h con scripts/aceptar-admin.ts)"}, escribir web/deployment.${networkName}.json.`);
  }
  for (const p of problemas) console.log(`PROBLEMA: ${p}`);
  if (!confirmado || problemas.length) {
    const nonce = desplegador === undefined ? 0 : await ethers.provider.getTransactionCount(desplegador.address);
    console.log(`Plan: no se envió ninguna transacción (nonce del desplegador: ${nonce}, bloque: ${await ethers.provider.getBlockNumber()}). Para desplegar: CONFIRM_DEPLOY=yes`);
    process.exit(confirmado ? 1 : 0); // con confirmación pero con problemas: error
  }
}
const tepuy = await ethers.deployContract("Tepuy", [RETRASO_ADMIN_SEG, desplegador.address]);
await tepuy.waitForDeployment();
const bloque = (await tepuy.deploymentTransaction()!.wait())!.blockNumber; // la web lee eventos desde aquí

// clave -> [signer, nombre del rol en el contrato]
const roles = {
  emisor: [emisor, "EMISOR"], custodio: [custodio, "CUSTODIO"], agenteKyc: [agenteKyc, "AGENTE_KYC"],
  supervisor: [supervisor, "SUPERVISOR"], oraculo: [oraculo, "ORACULO"], recuperador: [recuperador, "RECUPERADOR"],
} as const;
for (const [signer, nombre] of Object.values(roles)) {
  await (await tepuy.grantRole(await tepuy[nombre](), signer.address)).wait();
}
const verificados = demo ? [cuentaPrueba.address, inversionistaB.address] : [];
if (demo) {
  for (const v of verificados) await (await tepuy.connect(agenteKyc).setVerified(v, true)).wait();
  // El custodio atestigua antes de que el emisor pueda acuñar.
  await (await tepuy.connect(custodio).setAttestedShares(10000)).wait();
  await (await tepuy.connect(emisor).mint(cuentaPrueba.address, 1000)).wait();
  // Fecha de registro de demo (snapshot #1), tras acuñar.
  await (await tepuy.connect(emisor).snapshot()).wait();
  // Dividendo de demo: 1 acción nueva por cada 10 en el corte; se paga a los verificados.
  await (await tepuy.connect(emisor).declararDividendo(1, 1, 10)).wait();
  await (await tepuy.connect(emisor).distribuirDividendo(1, verificados)).wait();
}

await (await tepuy.beginDefaultAdminTransfer(admin.address)).wait();
// El retraso se cumple avanzando el reloj; en red pública hay que esperarlo (scripts/aceptar-admin.ts).
const traspasoPendiente = !local && !simulada;
if (!traspasoPendiente) {
  await ethers.provider.send("evm_increaseTime", [RETRASO_ADMIN_SEG + 1]);
  await ethers.provider.send("evm_mine", []);
  await (await tepuy.connect(admin).acceptDefaultAdminTransfer()).wait();

  await verificarRoles(tepuy, desplegador.address, { admin: admin.address, ...Object.fromEntries(Object.entries(roles).map(([k, [v]]) => [k, v.address])) } as Parameters<typeof verificarRoles>[2]);
} else console.log("Traspaso del admin iniciado: tras 24 h ejecuta scripts/aceptar-admin.ts (el desplegador conserva el rol hasta entonces).");

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
await (await tepuy.connect(oraculo).publishPrice(centimos, fecha, "0x" + createHash("sha256").update(archivo).digest("hex"))).wait();

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
  "function dividendo(uint256) view returns (uint256 numerador, uint256 denominador)",
  "function dividendoPagado(uint256, address) view returns (bool)",
  "event DividendoDeclarado(uint256 indexed snapId, uint256 numerador, uint256 denominador, address indexed emisor)",
  "event DividendoPagado(uint256 indexed snapId, address indexed tenedor, address indexed destino, uint256 monto)",
  "event DividendoOmitido(uint256 indexed snapId, address indexed tenedor, address indexed destino, uint256 monto)",
  "event FraccionPendiente(uint256 indexed snapId, address indexed tenedor, address indexed destino, uint256 resto)",
  "event SnapshotCreado(uint256 indexed id, uint48 bloque, address indexed emisor)",
  "function ultimoPrecio() view returns (uint256 centimos, bytes32 sha256Archivo, uint32 fecha, uint64 publicadoEn)",
  "event PrecioPublicado(uint32 indexed fecha, uint256 centimos, bytes32 sha256Archivo, address indexed oraculo)",
  "event TransferenciaForzada(address indexed from, address indexed to, uint256 amount, string motivo, address indexed recuperador)",
  "event CuentaRecuperada(address indexed perdida, address indexed nueva, uint256 saldo, string motivo, address indexed recuperador)",
  "event Transfer(address indexed from, address indexed to, uint256 value)",
  "event VerificacionCambiada(address indexed cuenta, bool verificado, address indexed agente)",
  "event CongelamientoCambiado(address indexed cuenta, bool congelada, address indexed supervisor)",
  "event AtestiguacionCambiada(uint256 anterior, uint256 nueva, address indexed custodio)",
  "event Paused(address account)",
  "event Unpaused(address account)",
];
const sinKyc = (await ethers.getSigners())[14]; // en red pública casi nunca existe: se omite
writeFileSync(fileURLToPath(new URL(`../web/deployment${local ? "" : `.${networkName}`}.json`, import.meta.url)), JSON.stringify({
  chainId: Number(chainId),
  address,
  bloque,
  verificados,
  // Cuenta 14 de Hardhat: sin roles ni KYC y fuera del simulador (usa 8-13). Demo de transferencia rechazada (S16).
  ...(sinKyc && { sinKyc: sinKyc.address }),
  // Nombres ficticios para la web (siempre "(demo)").
  etiquetas: { ...(demo && { [cuentaPrueba.address]: "Ana (demo)", [inversionistaB.address]: "Bruno (demo)" }), ...(sinKyc && { [sinKyc.address]: "Persona sin verificar (demo)" }) },
  ...(traspasoPendiente && { traspasoAdminPendiente: true }),
  roles: { admin: admin.address, ...Object.fromEntries(Object.entries(roles).map(([k, [v]]) => [k, v.address])) },
  abi,
}, null, 2));
console.log(`Tepuy desplegado en ${address}`);
