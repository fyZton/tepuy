// Prueba de scripts/deploy.ts contra redes SIMULADAS en proceso (nunca toca una red real).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, rmSync } from "node:fs";

const salida = "web/deployment.simArbitrum.json";
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(TEPUY_KEY_|CONFIRM_DEPLOY|ARBITRUM_SEPOLIA_RPC|SEPOLIA_RPC)/.test(k)));
const correr = (red, extra = {}) => {
  const r = spawnSync(process.execPath, ["node_modules/hardhat/dist/src/cli.js", "run", "scripts/deploy.ts", "--network", red],
    { env: { ...env, ...extra }, encoding: "utf8" });
  return { ...r, out: `${r.stdout}${r.stderr}` };
};
rmSync(salida, { force: true });

let r = correr("simArbitrum"); // sin confirmar: plan, exit 0, nada enviado
assert.equal(r.status, 0, r.out);
assert.match(r.out, /chainId: 421614/);
assert.match(r.out, /desplegador\s+0x[0-9a-fA-F]{40}\s+[0-9.]+ ETH/);
assert.match(r.out, /no se envió ninguna transacción \(nonce del desplegador: 0, bloque: 0\)/);
assert.ok(!existsSync(salida), "el plan no debe escribir el despliegue");

r = correr("simArbitrum", { CONFIRM_DEPLOY: "no" }); // solo "yes" cuenta
assert.equal(r.status, 0, r.out);
assert.ok(!existsSync(salida));

r = correr("simArbitrum", { CONFIRM_DEPLOY: "yes" });
assert.equal(r.status, 0, r.out);
assert.match(r.out, /Tepuy desplegado en 0x/);
const d = JSON.parse(readFileSync(salida, "utf8"));
assert.equal(d.chainId, 421614);
assert.equal(d.verificados.length, 2);
assert.ok(!d.traspasoAdminPendiente); // la simulada avanza el reloj y completa el traspaso
rmSync(salida);

r = correr("simAjena", { CONFIRM_DEPLOY: "yes" });
assert.notEqual(r.status, 0);
assert.match(r.out, /chainId no permitido: 1/);
assert.ok(!existsSync("web/deployment.simAjena.json"));
console.log("despliegue: OK");
