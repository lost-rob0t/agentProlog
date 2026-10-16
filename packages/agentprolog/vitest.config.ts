import { defineConfig } from "vitest/config";

export default defineConfig({
  server: { host: "127.0.0.1" },
  test: {
    include: ["test/**/*.test.ts"],
    testTimeout: 30000,
    hookTimeout: 30000,
  },
});
