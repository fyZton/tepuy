// Servidor estático mínimo para web/ (sin dependencias)
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const raiz = fileURLToPath(new URL("../web", import.meta.url));
const tipos = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript",
  ".json": "application/json",
  ".css": "text/css",
  ".svg": "image/svg+xml",
  ".png": "image/png",
};
const cabeceras = {
  "content-security-policy":
    "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self' http://127.0.0.1:8545; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
};
const responder = (res, estado, cuerpo, extra = {}) => {
  res.writeHead(estado, { ...cabeceras, ...extra });
  res.end(cuerpo);
};

createServer(async (req, res) => {
  try {
    let ruta = decodeURIComponent(new URL(req.url, "http://x").pathname);
    if (ruta.endsWith("/")) ruta += "index.html";
    const archivo = resolve(raiz, "." + ruta);
    if (!archivo.startsWith(raiz + sep)) return responder(res, 404, "No encontrado");
    const datos = await readFile(archivo);
    responder(res, 200, datos, { "content-type": tipos[extname(archivo)] ?? "application/octet-stream" });
  } catch (e) {
    if (e instanceof URIError || e instanceof TypeError) return responder(res, 400, "Solicitud inválida");
    if (e.code === "ENOENT" || e.code === "EISDIR") return responder(res, 404, "No encontrado");
    console.error(e);
    responder(res, 500, "Error interno");
  }
}).listen(3000, "127.0.0.1");
