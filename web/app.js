import { JsonRpcProvider, Contract } from "./vendor/ethers.min.js";

const $ = (id) => document.getElementById(id);

try {
  const respuesta = await fetch("deployment.json");
  if (!respuesta.ok) throw new Error(`deployment.json: ${respuesta.status}`);
  const { address, abi } = await respuesta.json();
  const provider = new JsonRpcProvider("http://127.0.0.1:8545", undefined, { staticNetwork: true });
  const token = new Contract(address, abi, provider);
  const [name, symbol, decimals, supply] = await Promise.all([
    token.name(), token.symbol(), token.decimals(), token.totalSupply(),
  ]);
  $("name").textContent = name;
  $("symbol").textContent = symbol;
  $("decimals").textContent = decimals.toString();
  $("supply").textContent = supply.toString();
} catch (e) {
  console.error(e);
  for (const id of ["name", "symbol", "decimals", "supply"]) $(id).textContent = "—";
  $("error").textContent = "No se pudo leer el contrato. Verifica que el nodo local (http://127.0.0.1:8545) esté encendido y que hayas ejecutado el despliegue.";
  $("error").hidden = false;
}
