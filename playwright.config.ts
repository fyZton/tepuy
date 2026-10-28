import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "e2e",
  workers: 1,
  use: { baseURL: "http://127.0.0.1:3000" },
  projects: [{ name: "chromium", use: { browserName: "chromium" } }],
  webServer: [
    { command: "npm run node", port: 8545, reuseExistingServer: false, timeout: 60_000 },
    { command: "npm run deploy:local && npm run web", port: 3000, reuseExistingServer: false, timeout: 60_000 },
  ],
});
