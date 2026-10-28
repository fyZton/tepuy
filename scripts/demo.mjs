// Un solo comando: nodo + despliegue + web + simulador. Ctrl+C apaga todo lo que levantó.
import { spawn, spawnSync } from "node:child_process";
import { connect } from "node:net";
import { mkdirSync, openSync } from "node:fs";

const hijos = [];
const ocupado = (puerto) => new Promise((ok) => {
  const s = connect(puerto, "127.0.0.1");
  s.once("connect", () => { s.destroy(); ok(true); });
  s.once("error", () => ok(false));
});
const esperar = async (cond, ms, que) => {
  for (const fin = Date.now() + ms; Date.now() < fin;) {
    if (await cond()) return;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`Tiempo agotado esperando: ${que}`);
};
// Un hijo está vivo mientras no haya salido ni fallado al arrancar.
const vivo = (h) => h.exitCode === null && !h.falloArranque;
const lanzar = (script, salida = "inherit") => {
  // detached en POSIX: grupo propio para poder matar el árbol con process.kill(-pid).
  const h = spawn(`npm run --silent ${script}`, { stdio: ["ignore", salida, salida], shell: true, detached: process.platform !== "win32" });
  h.on("error", (e) => { h.falloArranque = true; console.error(`No se pudo iniciar "${script}": ${e.message}`); apagar(1); });
  hijos.push(h);
  return h;
};
let saliendo = false;
function matarHijos() {
  // Con shell:true el PID es el de cmd.exe: en Windows hay que matar el árbol; solo se tocan procesos propios.
  for (const h of hijos) {
    if (h.exitCode !== null || !h.pid) continue;
    try {
      if (process.platform === "win32") spawnSync("taskkill", ["/PID", String(h.pid), "/T", "/F"], { stdio: "ignore" });
      else process.kill(-h.pid, "SIGTERM");
    } catch { /* ya terminó */ }
  }
}
function apagar(codigo) {
  if (saliendo) return;
  saliendo = true;
  matarHijos();
  process.exit(codigo);
}
process.on("SIGINT", () => apagar(0));
process.on("SIGTERM", () => apagar(0));
process.on("exit", () => { if (!saliendo) { saliendo = true; matarHijos(); } });

// Espera un puerto y falla si el hijo muere antes (o justo después) de que responda.
const listo = async (h, puerto, que) => {
  await esperar(async () => {
    if (!vivo(h)) throw new Error(`${que} se cerró antes de estar listo.`);
    return ocupado(puerto);
  }, 60_000, que);
  if (!vivo(h)) throw new Error(`${que} se cerró al arrancar (¿otro programa usa el puerto ${puerto}?).`);
};

try {
  for (const p of [8545, 3000]) {
    if (await ocupado(p)) {
      console.error(`El puerto ${p} ya está ocupado. Ciérralo y vuelve a intentar (no se apagó nada).`);
      process.exit(1);
    }
  }
  // El nodo imprime cientos de líneas técnicas: van a un archivo, no a la consola.
  mkdirSync("logs", { recursive: true });
  const log = openSync("logs/nodo.log", "w");
  console.log("Iniciando nodo local (su salida va a logs/nodo.log)…");
  const nodo = lanzar("node", log);
  nodo.on("exit", () => { if (!saliendo) { console.error("El nodo se apagó."); apagar(1); } });
  await listo(nodo, 8545, "El nodo");
  // Despliegue en silencio: solo se avisa si falla.
  const despliegue = lanzar("deploy:local", "ignore");
  const codigo = await new Promise((r) => { despliegue.on("exit", r); despliegue.on("error", () => r(1)); });
  if (codigo !== 0) throw new Error("El despliegue falló (corre `npm run deploy:local` para ver el detalle).");
  const web = lanzar("web", "ignore");
  web.on("exit", () => { if (!saliendo) { console.error("La web se apagó."); apagar(1); } });
  await listo(web, 3000, "La web");
  console.log("\n==============================\n  Abre http://127.0.0.1:3000\n==============================\n  (Ctrl+C para apagar todo)\n");
  lanzar("simular");
} catch (e) {
  console.error(e.message);
  apagar(1);
}
