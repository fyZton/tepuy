import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { test, expect } from "@playwright/test";

test("la página muestra Tepuy Demo y suministro 1000", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("#name")).toHaveText("Tepuy Demo");
  await expect(page.locator("#symbol")).toHaveText("TPUY");
  await expect(page.locator("#decimals")).toHaveText("0");
  await expect(page.locator("#supply")).toHaveText("1000");
  await expect(page.locator("#attested")).toHaveText("10000");
  await expect(page.locator("#usoPct")).toHaveText("10%");
  await expect(page.locator("#mercado")).toHaveText("Abierto");
  await expect(page.getByRole("note")).toContainText("No es un producto oficial");
});

test("la tabla de roles tiene 7 filas", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("#roles tbody tr")).toHaveCount(7);
  const dirs = await page.locator("#roles tbody td:last-child").allTextContents();
  expect(dirs.every((d) => /^0x[0-9a-fA-F]{40}$/.test(d))).toBe(true);
  expect(new Set(dirs).size).toBe(7);
});

test("muestra 2 inversionistas verificados con saldo 1000 y 0", async ({ page }) => {
  await page.goto("/");
  const filas = page.locator("#verificados tbody tr");
  await expect(filas).toHaveCount(2);
  await expect(filas.nth(0).locator("td").nth(1)).toHaveText("1000");
  await expect(filas.nth(1).locator("td").nth(1)).toHaveText("0");
  await expect(filas.nth(0).locator("td").nth(2)).toHaveText("Activo");
  await expect(filas.nth(1).locator("td").nth(2)).toHaveText("Activo");
  const dirs = await page.locator("#verificados tbody td:first-child").allTextContents();
  expect(dirs.every((d) => /^0x[0-9a-fA-F]{40}$/.test(d))).toBe(true);
  expect(new Set(dirs).size).toBe(2);
});

test("la sección del recuperador aparece sin movimientos", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Acciones del recuperador" })).toBeVisible();
  await expect(page.locator("#forzados-vacio")).toHaveText("Sin movimientos forzados");
});

test("muestra el precio de MVZ.A del fixture con su hash real", async ({ page }) => {
  const archivo = readFileSync("oraculo/tests/fixtures/20261027.dat");
  await page.goto("/");
  await expect(page.locator("#precio-bs")).toContainText("16.999,99");
  await expect(page.locator("#precio-fecha")).toHaveText("Cierre del 27/10/2026");
  await expect(page.locator("#precio-hash")).toHaveText("0x" + createHash("sha256").update(archivo).digest("hex"));
  await expect(page.locator("#precio-aviso")).toBeHidden();
});

test("muestra un error si el nodo no responde", async ({ page }) => {
  await page.route("http://127.0.0.1:8545/**", (route) => route.abort());
  await page.goto("/");
  await expect(page.locator("#error")).toContainText("No se pudo leer el contrato");
  await expect(page.locator("#supply")).toHaveText("—");
});
