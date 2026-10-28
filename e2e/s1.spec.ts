import { test, expect } from "@playwright/test";

test("la página muestra Tepuy Demo y suministro 1000", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("#name")).toHaveText("Tepuy Demo");
  await expect(page.locator("#symbol")).toHaveText("TPUY");
  await expect(page.locator("#decimals")).toHaveText("0");
  await expect(page.locator("#supply")).toHaveText("1000");
  await expect(page.getByRole("note")).toContainText("No es un producto oficial");
});

test("la tabla de roles tiene 7 filas", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("#roles tbody tr")).toHaveCount(7);
  const dirs = await page.locator("#roles tbody td:last-child").allTextContents();
  expect(dirs.every((d) => /^0x[0-9a-fA-F]{40}$/.test(d))).toBe(true);
  expect(new Set(dirs).size).toBe(7);
});

test("muestra un error si el nodo no responde", async ({ page }) => {
  await page.route("http://127.0.0.1:8545/**", (route) => route.abort());
  await page.goto("/");
  await expect(page.locator("#error")).toContainText("No se pudo leer el contrato");
  await expect(page.locator("#supply")).toHaveText("—");
});
