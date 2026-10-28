import { test, expect, type Page } from "@playwright/test";

const cargar = async (page: Page) => {
  await page.goto("/");
  await expect(page.locator("#sim-desde option")).not.toHaveCount(0);
};
const resultado = (page: Page) => page.locator("#sim-resultado");

test("el botón rápido muestra el rechazo por falta de KYC", async ({ page }) => {
  await cargar(page);
  await page.getByRole("button", { name: "Probar con alguien sin KYC" }).click();
  await expect(resultado(page)).toContainText("Rechazada por el contrato");
  await expect(resultado(page)).toContainText("no está verificada (sin KYC)");
  await expect(page.locator("#sim-tecnico")).toContainText("NoVerificado(0x");
});

test("Ana a Bruno con 1 muestra Permitida", async ({ page }) => {
  await cargar(page);
  await page.locator("#sim-desde").selectOption({ label: "Ana (demo)" });
  await page.locator("#sim-hacia").selectOption({ label: "Bruno (demo)" });
  await page.locator("#sim-cant").fill("1");
  await page.getByRole("button", { name: "Simular transferencia" }).click();
  await expect(resultado(page)).toContainText("Permitida: Ana (demo) puede pasarle 1 acción a Bruno (demo).");
});

test("una cantidad mayor que el saldo muestra el motivo de saldo", async ({ page }) => {
  await cargar(page);
  await page.locator("#sim-desde").selectOption({ label: "Ana (demo)" });
  await page.locator("#sim-hacia").selectOption({ label: "Bruno (demo)" });
  await page.locator("#sim-cant").fill("99999999");
  await page.getByRole("button", { name: "Simular transferencia" }).click();
  await expect(resultado(page)).toContainText("Rechazada por el contrato");
  await expect(resultado(page)).toContainText("Saldo insuficiente");
  await expect(page.locator("#sim-tecnico")).toContainText("ERC20InsufficientBalance(");
});

test("una dirección inválida da error de validación sin llamar al contrato", async ({ page }) => {
  await cargar(page);
  let llamadas = 0;
  // la página sondea cada 2 s; solo cuentan las simulaciones de transfer (selector a9059cbb)
  page.on("request", (r) => { if (r.url().includes(":8545") && (r.postData() ?? "").includes("a9059cbb")) llamadas++; });
  await page.locator("#sim-hacia").selectOption({ label: "Otra dirección…" });
  await page.locator("#sim-otra").fill("0x123");
  await page.getByRole("button", { name: "Simular transferencia" }).click();
  await expect(page.locator("#sim-validacion")).toContainText("no es válida");
  await expect(resultado(page)).toBeHidden();
  expect(llamadas).toBe(0);
});

test("simular no cambia saldos ni suministro", async ({ page }) => {
  await cargar(page);
  const leer = async () => ({
    supply: await page.locator("#supply").textContent(),
    ana: await page.locator("#verificados tbody tr").first().locator("td").nth(1).textContent(),
  });
  const antes = await leer();
  await page.getByRole("button", { name: "Probar con alguien sin KYC" }).click();
  await expect(resultado(page)).toContainText("Rechazada");
  await page.locator("#sim-desde").selectOption({ label: "Ana (demo)" });
  await page.locator("#sim-hacia").selectOption({ label: "Bruno (demo)" });
  await page.getByRole("button", { name: "Simular transferencia" }).click();
  await expect(resultado(page)).toContainText("Permitida");
  expect(await leer()).toEqual(antes);
});

test("en móvil la sección no genera scroll horizontal", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await cargar(page);
  await page.getByRole("button", { name: "Probar con alguien sin KYC" }).click();
  await expect(resultado(page)).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)).toBeLessThanOrEqual(0);
});
