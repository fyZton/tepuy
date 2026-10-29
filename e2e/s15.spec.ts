import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { test, expect } from "@playwright/test";

const ejecutar = promisify(execFile);

test("se ven los textos explicativos y el aviso de demo", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("note")).toContainText("Demo con datos de prueba en una red de prueba");
  await expect(page.getByText("Cada token TPUY representa 1 acción de MVZ.A")).toBeVisible();
  await expect(page.getByText("¿Qué es esto?")).toHaveCount(9);
  await expect(page.getByText("Emisor (crea acciones)")).toBeVisible();
  await expect(page.getByText("Supervisor (puede pausar todo, como SUNAVAL)")).toBeVisible();
  await expect(page.locator("#verif-n")).toHaveText("2");
  await expect(page.getByRole("heading", { name: "Operaciones en la cadena" })).toBeVisible();
});

test("al cargar, el feed muestra el historial del despliegue (más reciente arriba, sin enlace en local)", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("#feed li").first()).toBeVisible();
  await expect(page.locator("#feed-vacio")).toBeHidden();
  await expect(page.locator("#feed li").filter({ hasText: "El agente KYC verificó a Ana (demo)" })).not.toHaveCount(0);
  await expect(page.locator("#feed")).toHaveAttribute("aria-live", "polite");
  await expect(page.locator("#feed a")).toHaveCount(0); // red local: sin explorador
  const textos = await page.locator("#feed li").allTextContents();
  const kyc = textos.findIndex((t) => t.includes("verificó a Ana (demo)"));
  const emision = textos.findIndex((t) => /Se crearon 1\.?000 acciones nuevas para Ana \(demo\)/.test(t));
  expect(emision).toBeGreaterThanOrEqual(0);
  expect(emision).toBeLessThan(kyc); // en el despliegue se acuña después del KYC: más reciente, más arriba
});

test("en móvil no hay scroll horizontal", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await expect(page.locator("#supply")).not.toHaveText("Cargando…");
  const sobra = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(sobra).toBeLessThanOrEqual(0);
});

// Cambia el estado de la cadena (verifica y reparte acciones): depende de correr después de s1
// (workers: 1, despliegue nuevo en cada corrida).
test("el simulador agrega operaciones al feed sin recargar", async ({ page }) => {
  test.setTimeout(120_000);
  await page.goto("/");
  await expect(page.locator("#verif-n")).toHaveText("2");
  await expect(page.locator("#op-hoy")).toHaveText(/^\d+$/);
  const antes = Number(await page.locator("#op-hoy").textContent());
  await ejecutar("npm run simular", { shell: true, env: { ...process.env, SIM_OPERACIONES: "5", SIM_INTERVALO: "0.2", SIM_SEMILLA: "1" } });
  await expect(page.locator("#feed li").first()).toBeVisible({ timeout: 15_000 });
  await expect(page.locator("#feed li").filter({ hasText: "El agente KYC verificó a Carla (demo)" })).toHaveCount(1);
  await expect(page.locator("#verif-n")).toHaveText("6");
  await expect(page.locator("#verificados tbody tr")).toHaveCount(6);
  await expect.poll(async () => Number(await page.locator("#op-hoy").textContent())).toBeGreaterThan(antes + 5);
  await expect(page.locator("#feed-vacio")).toBeHidden();
});
