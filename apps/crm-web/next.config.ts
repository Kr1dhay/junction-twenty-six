import type { NextConfig } from "next";
const config: NextConfig = {
  transpilePackages: ["@edgecare/shared-types"],
  serverExternalPackages: ["better-sqlite3", "onnxruntime-node", "sharp"],
  // The skin CNN is read from disk at runtime; make sure deployments ship it with the route.
  outputFileTracingIncludes: { "/demo/skin/assess": ["./models/**/*"] },
};
export default config;
