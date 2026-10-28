import { JsonRpcProvider, Contract } from "./vendor/ethers.min.js";

const $ = (id) => document.getElementById(id);

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

// Céntimos (BigInt) a "Bs. 16.999,99" sin pasar por float.
const formatoBs = (c) => `Bs. ${new Intl.NumberFormat("es-VE").format(c / 100n)},${(c % 100n).toString().padStart(2, "0")}`;
const hace = (seg) => (seg < 60 ? "hace menos de 1 min" : seg < 3600 ? `hace ${Math.floor(seg / 60)} min` : `hace ${Math.floor(seg / 3600)} h`);

try {
  const respuesta = await fetch("deployment.json");
  if (!respuesta.ok) throw new Error(`deployment.json: ${respuesta.status}`);
  const { address, abi, roles = {}, verificados } = await respuesta.json();
  if (!address || !abi || !Object.keys(roles).length || !Array.isArray(verificados)) throw new Error("deployment.json incompleto");
  const provider = new JsonRpcProvider("http://127.0.0.1:8545", undefined, { staticNetwork: true });
  const token = new Contract(address, abi, provider);
  const [name, symbol, decimals, supply, attested, pausado] = await Promise.all([
    token.name(), token.symbol(), token.decimals(), token.totalSupply(), token.accionesAtestiguadas(), token.paused(),
  ]);
  $("mercado").textContent = pausado ? "Pausado por el supervisor" : "Abierto";
  $("name").textContent = name;
  $("symbol").textContent = symbol;
  $("decimals").textContent = decimals.toString();
  $("supply").textContent = supply.toString();
  $("attested").textContent = attested.toString();
  const pct = attested === 0n ? 0 : Number((supply * 10000n) / attested) / 100;
  $("uso").value = pct;
  $("usoPct").textContent = `${pct}%`;
  try {
    const [centimos, hash, fecha, publicadoEn] = await token.ultimoPrecio();
    if (fecha === 0n) {
      $("precio-vacio").textContent = "Aún no hay precio publicado";
    } else {
      const f = fecha.toString();
      $("precio-bs").textContent = formatoBs(centimos);
      $("precio-fecha").textContent = `Cierre del ${f.slice(6)}/${f.slice(4, 6)}/${f.slice(0, 4)}`;
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
  for (const [rol, dir] of Object.entries(roles)) {
    const fila = $("roles").tBodies[0].insertRow();
    fila.insertCell().textContent = rol;
    fila.insertCell().textContent = dir;
  }
  // Se lee isVerified en cadena: el JSON solo sugiere candidatos.
  for (const dir of verificados) {
    const [ok, congelada, saldo] = await Promise.all([token.isVerified(dir), token.isFrozen(dir), token.balanceOf(dir)]);
    const fila = $("verificados").tBodies[0].insertRow();
    fila.insertCell().textContent = dir;
    fila.insertCell().textContent = saldo.toString();
    // KYC primero, igual que en _update.
    fila.insertCell().textContent = !ok ? "No verificado" : congelada ? "Congelado" : "Activo";
  }
  try {
    const n = await token.snapshotCount();
    $("snap-vacio").textContent = "Aún no hay fecha de registro";
    if (n > 0n) {
      const bloque = await token.snapshotBlock(n);
      $("snap-titulo").textContent = `Snapshot #${n} en el bloque ${bloque} (saldos al cierre de ese bloque, ya definitivo)`;
      $("snap-saldos").tBodies[0].replaceChildren();
      for (const dir of verificados) {
        const [corte, actual] = await Promise.all([token.balanceOfAt(dir, n), token.balanceOf(dir)]);
        const fila = $("snap-saldos").tBodies[0].insertRow();
        for (const t of [dir, corte, actual]) fila.insertCell().textContent = t.toString();
      }
      $("snap-vacio").hidden = true;
      $("snap").hidden = false;
    }
  } catch (e) {
    console.error(e);
    $("snap-vacio").textContent = "No se pudo leer la fecha de registro.";
  }
  try {
    const n = await token.snapshotCount();
    $("div-vacio").textContent = "Aún no hay dividendos";
    // Último snapshot con dividendo declarado.
    let id = n;
    while (id > 0n && (await token.dividendo(id))[1] === 0n) id--;
    if (id > 0n) {
      const [num, den] = await token.dividendo(id);
      $("div-titulo").textContent = `Snapshot #${id}: ${num} acción nueva por cada ${den} en tenencia`;
      const filtro = (f) => token.queryFilter(f, 0);
      const evs = (await Promise.all([
        filtro(token.filters.DividendoPagado(id)), filtro(token.filters.DividendoOmitido(id)), filtro(token.filters.FraccionPendiente(id)),
      ])).flat().sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index);
      $("div-pagos").tBodies[0].replaceChildren();
      // Estado final por tenedor: una omisión solo se muestra si sigue sin pagarse (y la última de cada tenedor).
      const pagados = new Map(await Promise.all([...new Set(evs.map((e) => e.args.tenedor))].map(async (t) => [t, await token.dividendoPagado(id, t)])));
      const ultimaOmision = new Map(evs.filter((e) => e.eventName === "DividendoOmitido").map((e) => [e.args.tenedor, e]));
      for (const ev of evs) {
        if (ev.eventName === "DividendoOmitido" && (pagados.get(ev.args.tenedor) || ultimaOmision.get(ev.args.tenedor) !== ev)) continue;
        const fila = $("div-pagos").tBodies[0].insertRow();
        const celdas = ev.eventName === "FraccionPendiente"
          ? ["Fracción pendiente (en efectivo)", ev.args.tenedor, ev.args.destino, ev.args.resto]
          : [ev.eventName === "DividendoPagado" ? "Pagado" : "Omitido", ev.args.tenedor, ev.args.destino, ev.args.monto];
        for (const t of celdas) fila.insertCell().textContent = t.toString();
      }
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
    $("forzados-vacio").hidden = true;
    $("forzados").hidden = false;
    for (const ev of eventos) {
      const rec = ev.eventName === "CuentaRecuperada";
      const fila = $("forzados").tBodies[0].insertRow();
      const celdas = rec
        ? ["Recuperación", ev.args.perdida, ev.args.nueva, ev.args.saldo, ev.args.motivo]
        : ["Forzada", ev.args.from, ev.args.to, ev.args.amount, ev.args.motivo];
      for (const t of celdas) fila.insertCell().textContent = t.toString();
    }
  }
} catch (e) {
  console.error(e);
  $("uso").value = 0;
  for (const id of ["name", "symbol", "decimals", "supply", "attested", "usoPct", "mercado", "forzados-vacio", "precio-vacio", "snap-vacio", "div-vacio"]) $(id).textContent = "—";
  $("error").textContent = "No se pudo leer el contrato. Verifica que el nodo local (http://127.0.0.1:8545) esté encendido y que hayas ejecutado el despliegue.";
  $("error").hidden = false;
  $("precio").hidden = true;
  $("precio-vacio").hidden = false;
}
