import { JsonRpcProvider, Contract } from "./vendor/ethers.min.js";

const $ = (id) => document.getElementById(id);

try {
  const respuesta = await fetch("deployment.json");
  if (!respuesta.ok) throw new Error(`deployment.json: ${respuesta.status}`);
  const { address, abi, roles = {}, verificados } = await respuesta.json();
  if (!address || !abi || !Object.keys(roles).length || !Array.isArray(verificados)) throw new Error("deployment.json incompleto");
  const provider = new JsonRpcProvider("http://127.0.0.1:8545", undefined, { staticNetwork: true });
  const token = new Contract(address, abi, provider);
  const [name, symbol, decimals, supply] = await Promise.all([
    token.name(), token.symbol(), token.decimals(), token.totalSupply(),
  ]);
  $("name").textContent = name;
  $("symbol").textContent = symbol;
  $("decimals").textContent = decimals.toString();
  $("supply").textContent = supply.toString();
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
} catch (e) {
  console.error(e);
  for (const id of ["name", "symbol", "decimals", "supply"]) $(id).textContent = "—";
  $("error").textContent = "No se pudo leer el contrato. Verifica que el nodo local (http://127.0.0.1:8545) esté encendido y que hayas ejecutado el despliegue.";
  $("error").hidden = false;
}
