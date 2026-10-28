// Simulador de operaciones demo: inversionistas ficticios operando entre sí hasta Ctrl+C.
// Variables: SIM_INTERVALO (seg, def. 2), SIM_SEMILLA (número), SIM_OPERACIONES (N y salir).
import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { network } from "hardhat";

const RUTA_JSON = fileURLToPath(new URL("../web/deployment.json", import.meta.url));
const NOMBRES = ["Ana", "Bruno", "Carla", "Diego", "Elena", "Félix"];
const PRIMER_INDICE = 8; // cuentas 0-7 ya tienen roles en deploy.ts

const { ethers } = await network.getOrCreate();
const { chainId } = await ethers.provider.getNetwork();
if (chainId !== 31337n) throw new Error(`Solo redes locales (31337), chainId actual: ${chainId}`);

const despliegue = JSON.parse(readFileSync(RUTA_JSON, "utf8")) as {
  address: string; verificados: string[]; etiquetas?: Record<string, string>;
};
const signers = await ethers.getSigners();
const rolSigner = async (clave: string) => {
  const dir = (JSON.parse(readFileSync(RUTA_JSON, "utf8")).roles as Record<string, string>)[clave];
  const s = signers.find((x) => x.address === dir);
  if (!s) throw new Error(`No hay cuenta de prueba para el rol ${clave}`);
  return s;
};
const [emisor, custodio, agenteKyc, supervisor, oraculo] = await Promise.all(
  ["emisor", "custodio", "agenteKyc", "supervisor", "oraculo"].map(rolSigner),
);
const tepuy = await ethers.getContractAt("Tepuy", despliegue.address);
const inversionistas = NOMBRES.map((n, i) => ({ nombre: `${n} (demo)`, signer: signers[PRIMER_INDICE + i] }));

const bs = (c: bigint) => `${new Intl.NumberFormat("es-VE").format(c / 100n)},${(c % 100n).toString().padStart(2, "0")} Bs`;
const FRASES: Record<string, string> = {
  SinSaldo: "no tiene saldo", CuentaCongelada: "la cuenta está congelada", NoVerificado: "la cuenta no está verificada",
  TopeExcedido: "se superaría el tope de acciones guardadas", EnforcedPause: "el mercado está pausado",
  FechaFutura: "la fecha del precio queda demasiado lejos en el futuro", FechaNoCreciente: "la fecha del precio no es mayor que la anterior",
};
function motivo(e: unknown): string {
  const err = e as { data?: string; shortMessage?: string; message?: string; info?: { error?: { data?: string } } };
  const data = err.data ?? err.info?.error?.data;
  if (typeof data === "string" && data.length >= 10) {
    const p = tepuy.interface.parseError(data);
    if (p) return `${FRASES[p.name] ?? p.name}${p.args.length ? ` (${p.name}: ${p.args.join(", ")})` : ` (${p.name})`}`;
  }
  return err.shortMessage ?? err.message ?? String(e);
}
// Ejecuta una tx; si revierte, lo cuenta y sigue. Devuelve si salió bien.
let fallos = 0;
async function intentar(descripcion: string, tx: () => Promise<{ wait: () => Promise<unknown> }>): Promise<boolean> {
  try {
    await (await tx()).wait();
    console.log(descripcion);
    return true;
  } catch (e) {
    fallos++;
    console.log(`No se pudo: ${descripcion} Motivo: ${motivo(e)}`);
    return false;
  }
}

// --- Configuración (antes de la preparación, para que Ctrl+C funcione desde el inicio) ---
const numeroEnv = (nombre: string, def: number, min: number): number => {
  const v = process.env[nombre];
  if (v === undefined || v === "") return def;
  const x = Number(v);
  if (!Number.isFinite(x) || x < min) throw new Error(`${nombre}="${v}" no es válido: debe ser un número mayor o igual a ${min}.`);
  return x;
};
let semilla = numeroEnv("SIM_SEMILLA", Date.now(), 0) >>> 0;
const azar = () => { // mulberry32
  semilla = (semilla + 0x6d2b79f5) >>> 0;
  let t = semilla;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const entre = (a: number, b: number) => a + Math.floor(azar() * (b - a + 1));
const intervalo = numeroEnv("SIM_INTERVALO", 2, 0) * 1000;
const maxOps = numeroEnv("SIM_OPERACIONES", Infinity, 0);

let parar = false;
let despertar = () => {};
process.on("SIGINT", () => { parar = true; despertar(); });
const dormir = (ms: number) => new Promise<void>((r) => { const t = setTimeout(r, ms); despertar = () => { clearTimeout(t); r(); }; });

// --- Preparación idempotente ---
const verif = new Set(despliegue.verificados);
const etiquetas = { ...despliegue.etiquetas };
let preparado = true;
for (const { nombre, signer } of inversionistas) {
  if (parar) break;
  etiquetas[signer.address] = nombre;
  if (!(await tepuy.isVerified(signer.address))) {
    preparado = (await intentar(`El agente KYC verificó a ${nombre}.`, () => tepuy.connect(agenteKyc).setVerified(signer.address, true))) && preparado;
  }
  verif.add(signer.address);
  if ((await tepuy.balanceOf(signer.address)) === 0n) {
    const monto = BigInt(200 + 100 * entre(0, 8));
    const libres = (await tepuy.accionesAtestiguadas()) - (await tepuy.totalSupply());
    if (libres < monto) {
      preparado = (await intentar("El custodio subió las acciones guardadas.", async () => tepuy.connect(custodio).setAttestedShares((await tepuy.totalSupply()) + monto + 10000n))) && preparado;
    }
    preparado = (await intentar(`Se crearon ${monto} acciones nuevas para ${nombre}.`, () => tepuy.connect(emisor).mint(signer.address, monto))) && preparado;
  }
}
if (!preparado) {
  console.error("No se pudo preparar a los inversionistas demo (motivos arriba). Revisa que el nodo esté recién desplegado con `npm run deploy:local`.");
  process.exit(1);
}
// Escritura atómica: la web puede leer el archivo en cualquier momento.
const actual = { ...JSON.parse(readFileSync(RUTA_JSON, "utf8")), verificados: [...verif], etiquetas };
writeFileSync(`${RUTA_JSON}.tmp`, JSON.stringify(actual, null, 2));
renameSync(`${RUTA_JSON}.tmp`, RUTA_JSON);
if (!parar) console.log("Listo: 6 inversionistas demo preparados. Ctrl+C para terminar.\n");

// --- Bucle ---
const aFecha = (n: number) => new Date(Date.UTC(Math.floor(n / 10000), (Math.floor(n / 100) % 100) - 1, n % 100));
const deFecha = (d: Date) => Number(d.toISOString().slice(0, 10).replaceAll("-", ""));

const conteo = { transferencias: 0, precios: 0, congelamientos: 0 };
let congelada: { nombre: string; dir: string; desde: number } | undefined;

async function publicarPrecio() {
  const [centimos, , fecha] = await tepuy.ultimoPrecio();
  const ahora = (await ethers.provider.getBlock("latest"))!.timestamp;
  // Sin precio previo arranca en la fecha de hoy; si no, el día siguiente al último.
  const dia = aFecha(fecha === 0n ? deFecha(new Date(ahora * 1000)) : Number(fecha));
  if (fecha !== 0n) dia.setUTCDate(dia.getUTCDate() + 1);
  const nueva = deFecha(dia);
  if (nueva > deFecha(new Date((ahora + 2 * 86400) * 1000))) {
    console.log("Se saltó la publicación de precio: la fecha del siguiente día quedaría demasiado en el futuro.");
    return;
  }
  const previo = fecha === 0n ? 1699999n : centimos;
  const nuevo = previo + (previo * BigInt(entre(-200, 200))) / 10000n;
  const hash = "0x" + createHash("sha256").update(`simulado-${nueva}-${nuevo}`).digest("hex");
  if (await intentar(`Se publicó el precio: ${bs(nuevo)} (cierre ${nueva}).`, () => tepuy.connect(oraculo).publishPrice(nuevo, nueva, hash))) conteo.precios++;
}

let n = 0;
while (!parar && n < maxOps) {
  n++;
  const r = azar();
  // Probabilidades fijas por operación; si ya hay una cuenta congelada, "congelar" cae en transferencia.
  const tipo = r < 1 / 30 ? "congelar" : r < 1 / 30 + 1 / 15 ? "precio" : "transferir";
  if (congelada && n - congelada.desde >= 3) {
    const { nombre, dir } = congelada;
    congelada = undefined;
    await intentar(`Se descongeló la cuenta de ${nombre}.`, () => tepuy.connect(supervisor).setAddressFrozen(dir, false));
  } else if (tipo === "congelar" && !congelada) {
    const v = inversionistas[entre(0, inversionistas.length - 1)];
    if (await intentar(`Se congeló la cuenta de ${v.nombre}.`, () => tepuy.connect(supervisor).setAddressFrozen(v.signer.address, true))) {
      congelada = { nombre: v.nombre, dir: v.signer.address, desde: n };
      conteo.congelamientos++;
    }
  } else if (tipo === "precio") {
    await publicarPrecio();
  } else {
    const saldos = await Promise.all(inversionistas.map(async (i) => ({ ...i, saldo: await tepuy.balanceOf(i.signer.address) })));
    const libres = saldos.filter((i) => i.signer.address !== congelada?.dir);
    const origenes = libres.filter((i) => i.saldo > 0n);
    if (origenes.length === 0 || libres.length < 2) {
      console.log("Nadie tiene saldo para transferir; se omite esta operación.");
    } else {
      const de = origenes[entre(0, origenes.length - 1)];
      const otros = libres.filter((i) => i !== de);
      const a = otros[entre(0, otros.length - 1)];
      const monto = BigInt(Math.min(entre(1, 20), Number(de.saldo)));
      if (await intentar(`${de.nombre} le pasó ${monto} ${monto === 1n ? "acción" : "acciones"} a ${a.nombre}.`, () => tepuy.connect(de.signer).transfer(a.signer.address, monto))) conteo.transferencias++;
    }
  }
  if (!parar && n < maxOps) await dormir(intervalo);
}
if (congelada) {
  await intentar(`Se descongeló la cuenta de ${congelada.nombre}.`, () => tepuy.connect(supervisor).setAddressFrozen(congelada!.dir, false));
}
console.log(`\nResumen: ${conteo.transferencias} transferencias, ${conteo.precios} precios, ${conteo.congelamientos} congelamientos, ${fallos} fallos.`);
process.exit(0);
