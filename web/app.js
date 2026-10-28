import { JsonRpcProvider, Contract } from "./vendor/ethers.min.js";

const $ = (id) => document.getElementById(id);
const MAX_FEED = 50;
const NBSP = " ";
const SIN_DATOS = ["name", "symbol", "decimals", "supply", "attested", "usoPct", "mercado", "forzados-vacio", "precio-vacio", "snap-vacio", "div-vacio"];
// Eventos que obligan a releer dividendos y movimientos del recuperador.
const EVENTOS_PESADOS = new Set(["DividendoDeclarado", "DividendoPagado", "DividendoOmitido", "FraccionPendiente", "TransferenciaForzada", "CuentaRecuperada", "SnapshotCreado"]);

// Se registra antes de cualquier await: el botón funciona aunque la carga falle o tarde.
$("copiar-hash").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText($("precio-hash").textContent);
    $("copiar-hash").textContent = "Copiado";
  } catch {
    $("copiar-hash").textContent = "No se pudo copiar";
  }
  setTimeout(() => { $("copiar-hash").textContent = "Copiar"; }, 2000);
});

// Céntimos (BigInt) a "16.999,99" sin pasar por float.
const numBs = (c) => `${new Intl.NumberFormat("es-VE").format(c / 100n)},${(c % 100n).toString().padStart(2, "0")}`;
const formatoBs = (c) => `Bs. ${numBs(c)}`;
const hace = (seg) => (seg < 60 ? "hace menos de 1 min" : seg < 3600 ? `hace ${Math.floor(seg / 60)} min` : `hace ${Math.floor(seg / 3600)} h`);
const acciones = (n) => `${n.toLocaleString("es-VE")} ${n === 1n ? "acción" : "acciones"}`;
const nuevas = (n) => (n === 1n ? "nueva" : "nuevas");
const fechaBonita = (f) => `${f.slice(6)}/${f.slice(4, 6)}/${f.slice(0, 4)}`;
const corta = (d) => `${d.slice(0, 6)}…${d.slice(-4)}`;

const ROLES = {
  admin: "Administrador (cambia quién tiene cada rol, con 1 día de espera)",
  emisor: "Emisor (crea acciones)",
  custodio: "Custodio (la Caja Venezolana certifica cuántas guarda)",
  agenteKyc: "Agente KYC (verifica identidad)",
  supervisor: "Supervisor (puede pausar todo, como SUNAVAL)",
  oraculo: "Oráculo (publica el precio oficial)",
  recuperador: "Recuperador (rescata cuentas perdidas)",
};

let etiquetas = {}; // dirección en minúsculas -> nombre ficticio "(demo)"
const nombre = (dir) => etiquetas[dir.toLowerCase()] ?? corta(dir);

// Con etiqueta: nombre y dirección abreviada en pequeño. Sin etiqueta: la dirección completa.
function celdaDir(celda, dir) {
  const et = etiquetas[dir.toLowerCase()];
  if (!et) { celda.textContent = dir; return; }
  const chica = document.createElement("small");
  chica.textContent = corta(dir);
  chica.className = "dir";
  celda.title = dir;
  celda.append(et, chica);
}
// Crea la fila sin tocar la tabla: así una carga que falla a medias no la deja vacía.
function fila(valores) {
  const tr = document.createElement("tr");
  for (const v of valores) {
    const td = document.createElement("td");
    if (typeof v === "object") celdaDir(td, v.dir); else td.textContent = v;
    tr.append(td);
  }
  return tr;
}
const dir = (d) => ({ dir: d });

let token;
let provider;
let direccion;

async function leerConfig() {
  const respuesta = await fetch("deployment.json", { cache: "no-store" });
  if (!respuesta.ok) throw new Error(`deployment.json: ${respuesta.status}`);
  const cfg = await respuesta.json();
  if (!cfg.address || !cfg.abi || !Object.keys(cfg.roles ?? {}).length || !Array.isArray(cfg.verificados)) throw new Error("deployment.json incompleto");
  etiquetas = Object.fromEntries(Object.entries(cfg.etiquetas ?? {}).map(([k, v]) => [k.toLowerCase(), v]));
  return cfg;
}

// Lee el contrato y repinta. conEventos: también dividendos y movimientos del recuperador (consultas más pesadas).
async function cargar(conEventos) {
  const { roles, verificados } = await leerConfig();
  const [name, symbol, decimals, supply, attested, pausado] = await Promise.all([
    token.name(), token.symbol(), token.decimals(), token.totalSupply(), token.accionesAtestiguadas(), token.paused(),
  ]);
  $("mercado").textContent = pausado ? "Pausado por el supervisor" : "Abierto";
  $("name").textContent = name;
  $("symbol").textContent = symbol;
  $("decimals").textContent = decimals.toString();
  $("supply").textContent = supply.toString();
  $("attested").textContent = attested.toString();
  const pct = attested === 0n ? 0 : Math.round(Number((supply * 10000n) / attested) / 100);
  $("uso").value = pct;
  $("usoPct").textContent = `${pct}%`;
  $("respaldo").textContent = attested > supply
    ? `100${NBSP}% respaldado: hay más acciones guardadas que tokens.`
    : attested === supply ? `100${NBSP}% respaldado: hay justo tantas acciones guardadas como tokens.` : "Atención: hay más tokens que acciones guardadas.";
  try {
    const [centimos, hash, fecha, publicadoEn] = await token.ultimoPrecio();
    if (fecha === 0n) {
      $("precio-vacio").textContent = "Aún no hay precio publicado";
    } else {
      const f = fecha.toString();
      $("precio-bs").textContent = formatoBs(centimos);
      $("card-precio").textContent = formatoBs(centimos);
      $("precio-fecha").textContent = `Cierre del ${fechaBonita(f)}`;
      $("card-fecha").textContent = `Cierre del ${fechaBonita(f)}`;
      $("precio-hash").textContent = hash;
      // Reloj: el mayor entre el último bloque y el navegador (el nodo local puede adelantar su tiempo).
      const ahora = Math.max((await provider.getBlock("latest")).timestamp, Math.floor(Date.now() / 1000));
      const seg = Math.max(0, ahora - Number(publicadoEn));
      $("precio-edad").textContent = hace(seg);
      // Días de calendario (UTC) entre la fecha de cierre y hoy.
      const hoy = new Date();
      const dias = Math.round((Date.UTC(hoy.getUTCFullYear(), hoy.getUTCMonth(), hoy.getUTCDate()) - Date.UTC(+f.slice(0, 4), +f.slice(4, 6) - 1, +f.slice(6))) / 86400000);
      $("precio-aviso").hidden = seg <= 86400 && dias <= 3;
      $("precio-vacio").hidden = true;
      $("precio").hidden = false;
    }
  } catch (e) {
    console.error(e);
    $("precio").hidden = true;
    $("precio-vacio").hidden = false;
    $("precio-vacio").textContent = "No se pudo leer el precio.";
  }
  $("roles").tBodies[0].replaceChildren(...Object.entries(roles).map(([rol, d]) => fila([ROLES[rol] ?? rol, dir(d)])));
  // Se lee isVerified en cadena: el JSON solo sugiere candidatos.
  const estados = await Promise.all(verificados.map((d) => Promise.all([token.isVerified(d), token.isFrozen(d), token.balanceOf(d)])));
  // KYC primero, igual que en _update.
  $("verificados").tBodies[0].replaceChildren(...verificados.map((d, i) => {
    const [ok, congelada, saldo] = estados[i];
    return fila([dir(d), saldo.toString(), !ok ? "No verificado" : congelada ? "Congelado" : "Activo"]);
  }));
  $("verif-n").textContent = estados.filter(([ok]) => ok).length.toString();
  try {
    const n = await token.snapshotCount();
    $("snap-vacio").textContent = "Aún no hay fecha de registro";
    if (n > 0n) {
      const bloque = await token.snapshotBlock(n);
      const filas = [];
      for (const d of verificados) {
        const [corte, actual] = await Promise.all([token.balanceOfAt(d, n), token.balanceOf(d)]);
        filas.push(fila([dir(d), corte.toString(), actual.toString()]));
      }
      $("snap-titulo").textContent = `Snapshot #${n} en el bloque ${bloque} (saldos al cierre de ese bloque, ya definitivo)`;
      $("snap-saldos").tBodies[0].replaceChildren(...filas);
      $("snap-vacio").hidden = true;
      $("snap").hidden = false;
    }
  } catch (e) {
    console.error(e);
    $("snap-vacio").textContent = "No se pudo leer la fecha de registro.";
  }
  if (conEventos) await cargarEventos();
}

// Dividendos y movimientos del recuperador: solo al inicio o cuando aparecen sus eventos.
async function cargarEventos() {
  try {
    const n = await token.snapshotCount();
    $("div-vacio").textContent = "Aún no hay dividendos";
    // Último snapshot con dividendo declarado.
    let id = n;
    while (id > 0n && (await token.dividendo(id))[1] === 0n) id--;
    if (id > 0n) {
      const [num, den] = await token.dividendo(id);
      const filtro = (f) => token.queryFilter(f, 0);
      const evs = (await Promise.all([
        filtro(token.filters.DividendoPagado(id)), filtro(token.filters.DividendoOmitido(id)), filtro(token.filters.FraccionPendiente(id)),
      ])).flat().sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index);
      // Estado final por tenedor: una omisión solo se muestra si sigue sin pagarse (y la última de cada tenedor).
      const pagados = new Map(await Promise.all([...new Set(evs.map((e) => e.args.tenedor))].map(async (h) => [h, await token.dividendoPagado(id, h)])));
      const ultimaOmision = new Map(evs.filter((e) => e.eventName === "DividendoOmitido").map((e) => [e.args.tenedor, e]));
      const filas = [];
      for (const ev of evs) {
        if (ev.eventName === "DividendoOmitido" && (pagados.get(ev.args.tenedor) || ultimaOmision.get(ev.args.tenedor) !== ev)) continue;
        filas.push(fila(ev.eventName === "FraccionPendiente"
          ? ["Fracción pendiente (en efectivo)", dir(ev.args.tenedor), dir(ev.args.destino), ev.args.resto.toString()]
          : [ev.eventName === "DividendoPagado" ? "Pagado" : "Omitido", dir(ev.args.tenedor), dir(ev.args.destino), ev.args.monto.toString()]));
      }
      $("div-titulo").textContent = `Snapshot #${id}: ${num} acción nueva por cada ${den} en tenencia`;
      $("div-pagos").tBodies[0].replaceChildren(...filas);
      $("div-vacio").hidden = true;
      $("div").hidden = false;
    }
  } catch (e) {
    console.error(e);
    $("div-vacio").textContent = "No se pudo leer el dividendo.";
  }
  const [forzadas, recuperadas] = await Promise.all([
    token.queryFilter(token.filters.TransferenciaForzada()),
    token.queryFilter(token.filters.CuentaRecuperada()),
  ]);
  const eventos = [...forzadas, ...recuperadas].sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index);
  $("forzados-vacio").textContent = "Sin movimientos forzados";
  if (eventos.length) {
    $("forzados").tBodies[0].replaceChildren(...eventos.map((ev) => fila(ev.eventName === "CuentaRecuperada"
      ? ["Recuperación", dir(ev.args.perdida), dir(ev.args.nueva), ev.args.saldo.toString(), ev.args.motivo]
      : ["Forzada", dir(ev.args.from), dir(ev.args.to), ev.args.amount.toString(), ev.args.motivo])));
    $("forzados-vacio").hidden = true;
    $("forzados").hidden = false;
  }
}

// Evento de la cadena a una frase en español simple; null si no se muestra en el feed.
function describir(p) {
  const a = p.args;
  switch (p.name) {
    case "Transfer":
      if (/^0x0+$/.test(a.from)) return `Se crearon ${acciones(a.value)} ${nuevas(a.value)} para ${nombre(a.to)}`;
      if (/^0x0+$/.test(a.to)) return `Se retiraron ${acciones(a.value)} de ${nombre(a.from)}`;
      return `${nombre(a.from)} le pasó ${acciones(a.value)} a ${nombre(a.to)}`;
    case "VerificacionCambiada":
      return a.verificado ? `El agente KYC verificó a ${nombre(a.cuenta)}` : `El agente KYC quitó la verificación a ${nombre(a.cuenta)}`;
    case "CongelamientoCambiado":
      return a.congelada ? `Se congeló la cuenta de ${nombre(a.cuenta)}` : `Se descongeló la cuenta de ${nombre(a.cuenta)}`;
    case "PrecioPublicado": return `Se publicó el precio: ${numBs(a.centimos)} Bs`;
    case "Paused": return "El supervisor pausó el mercado";
    case "Unpaused": return "El supervisor reanudó el mercado";
    case "AtestiguacionCambiada": return `El custodio ahora certifica ${acciones(a.nueva)} guardadas`;
    default: return null;
  }
}
const parsear = (l) => { try { return token.interface.parseLog({ topics: l.topics, data: l.data }); } catch { return null; } };
const interpretar = (l) => { const p = parsear(l); return p ? describir(p) : null; };

// Hora del bloque (cadena), una consulta por bloque y con caché.
const horas = new Map();
async function horaBloque(n) {
  if (!horas.has(n)) {
    horas.set(n, (await provider.getBlock(n)).timestamp);
    if (horas.size > 500) horas.delete(horas.keys().next().value);
  }
  return horas.get(n);
}

let ultimoBloque = 0;
let opsHoy = 0;
const pintarOps = () => { $("op-hoy").textContent = opsHoy.toString(); };

// Operaciones del día de la cadena (por la fecha del último bloque), de los bloques más nuevos a los más viejos, en lotes.
async function contarHoy() {
  const t = await horaBloque(ultimoBloque);
  const inicio = t - (t % 86400);
  const logs = (await provider.getLogs({ address: direccion, fromBlock: 0, toBlock: ultimoBloque })).filter((l) => interpretar(l));
  const porBloque = new Map();
  for (const l of logs) porBloque.set(l.blockNumber, (porBloque.get(l.blockNumber) ?? 0) + 1);
  const bloques = [...porBloque.keys()].sort((a, b) => b - a);
  let n = 0;
  for (let i = 0; i < bloques.length; i += 10) {
    const lote = bloques.slice(i, i + 10);
    const tiempos = await Promise.all(lote.map(horaBloque));
    let fin = false;
    lote.forEach((b, j) => { if (tiempos[j] >= inicio) n += porBloque.get(b); else fin = true; });
    if (fin) break;
  }
  opsHoy = n;
  pintarOps();
}

function agregarAlFeed(texto, segundos) {
  const li = document.createElement("li");
  const hora = document.createElement("time");
  hora.textContent = new Date(segundos * 1000).toLocaleTimeString("es-VE", { hour12: false });
  const t = document.createElement("span");
  t.textContent = texto;
  li.append(hora, t);
  $("feed").prepend(li);
  while ($("feed").children.length > MAX_FEED) $("feed").lastElementChild.remove();
  $("feed-vacio").hidden = true;
}

// Cada 2 s: eventos nuevos al feed y, si hubo alguno, se releen tarjetas y tablas.
let ocupado = false;
async function sondear() {
  if (ocupado) return;
  ocupado = true;
  try {
    const actual = await provider.getBlockNumber();
    if (actual < ultimoBloque) { // el nodo se reinició: se vuelve a empezar
      ultimoBloque = actual;
      horas.clear();
      await cargar(true);
      await contarHoy();
    } else if (actual > ultimoBloque) {
      const logs = await provider.getLogs({ address: direccion, fromBlock: ultimoBloque + 1, toBlock: actual });
      ultimoBloque = actual;
      if (logs.length) {
        const eventos = logs.map((l) => ({ l, p: parsear(l) })).filter((x) => x.p);
        await cargar(eventos.some((x) => EVENTOS_PESADOS.has(x.p.name))).catch(console.error); // primero las etiquetas nuevas
        let nuevos = 0;
        for (const { l, p } of eventos) {
          const texto = describir(p);
          if (texto) { agregarAlFeed(texto, await horaBloque(l.blockNumber)); nuevos++; }
        }
        opsHoy += nuevos;
        pintarOps();
      }
    }
  } catch (e) {
    console.error(e);
  } finally {
    ocupado = false;
  }
}

try {
  const cfg = await leerConfig();
  provider = new JsonRpcProvider("http://127.0.0.1:8545", undefined, { staticNetwork: true });
  token = new Contract(cfg.address, cfg.abi, provider);
  direccion = cfg.address;
  ultimoBloque = await provider.getBlockNumber(); // antes de cargar: no se pierde nada entre la carga y el primer sondeo
  await cargar(true);
  await contarHoy();
  setInterval(sondear, 2000);
} catch (e) {
  console.error(e);
  $("uso").value = 0;
  for (const id of SIN_DATOS) $(id).textContent = "—";
  $("error").textContent = "No se pudo leer el contrato. Verifica que el nodo local (http://127.0.0.1:8545) esté encendido y que hayas ejecutado el despliegue.";
  $("error").hidden = false;
  $("precio").hidden = true;
  $("precio-vacio").hidden = false;
}
