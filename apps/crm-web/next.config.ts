import type { NextConfig } from "next";
const config: NextConfig = { transpilePackages: ["@edgecare/shared-types"], serverExternalPackages: ["better-sqlite3"] };
export default config;
