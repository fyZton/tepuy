// Segundo paso del despliegue en red pública: tras el retraso de 24 h, el admin acepta el traspaso.
// Uso: CONFIRM_DEPLOY=yes npx hardhat run scripts/aceptar-admin.ts --network arbitrumSepolia
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { network } from "hardhat";
import { verificarRoles } from "./verificar-roles.ts";

const { ethers, networkName } = await network.getOrCreate();
const { chainId } = await ethers.provider.getNetwork();
if (![421614n, 11155111n].includes(chainId)) throw new Error(`Solo testnets públicas (421614, 11155111), chainId: ${chainId}`);
const ruta = fileURLToPath(new URL(`../web/deployment.${networkName}.json`, import.meta.url));
const info = JSON.parse(readFileSync(ruta, "utf8"));
if (info.chainId !== Number(chainId)) throw new Error(`El despliegue es de la red ${info.chainId}, la red actual es ${chainId}`);
const [desplegador, admin] = await ethers.getSigners();
if (admin?.address !== info.roles.admin) throw new Error("La clave TEPUY_KEY_ADMIN no corresponde al admin del despliegue");
const tepuy = await ethers.getContractAt("Tepuy", info.address);
console.log(`Contrato ${info.address} en ${networkName}; admin actual: ${await tepuy.defaultAdmin()}`);
if (process.env.CONFIRM_DEPLOY !== "yes") {
  console.log("Plan: aceptar el traspaso del admin. No se envió nada. Para ejecutar: CONFIRM_DEPLOY=yes");
  process.exit(0);
}
await (await tepuy.connect(admin).acceptDefaultAdminTransfer()).wait();
await verificarRoles(tepuy, desplegador.address, info.roles);
delete info.traspasoAdminPendiente;
writeFileSync(ruta, JSON.stringify(info, null, 2));
console.log("Traspaso aceptado: el desplegador ya no tiene roles de admin.");
