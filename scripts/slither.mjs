// Ejecuta Slither del venv con su carpeta Scripts en el PATH (para solc)
import { spawnSync } from "node:child_process";
import { delimiter, resolve } from "node:path";

const scripts = resolve(".venv-slither/Scripts");
const r = spawnSync(
  "slither",
  ["contracts/Tepuy.sol", "--solc-remaps", "@openzeppelin/=node_modules/@openzeppelin/", "--filter-paths", "node_modules"],
  { stdio: "inherit", env: { ...process.env, PATH: scripts + delimiter + process.env.PATH }, shell: true },
);
process.exit(r.status ?? 1);
