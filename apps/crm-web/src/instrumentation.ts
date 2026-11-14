/** Runs once when a server instance starts: logs which features are disabled and which variables they need. */
export async function register() {
  if (process.env.NEXT_RUNTIME !== "nodejs") return;
  const { logEnvironment } = await import("./server/env-check");
  logEnvironment();
}
