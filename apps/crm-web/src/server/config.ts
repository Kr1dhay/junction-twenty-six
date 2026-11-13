export function requireDemoMode() {
  if (process.env.DEMO_MODE !== "true" || process.env.CHAIN !== "mock" || process.env.LLM !== "ondevice") {
    throw new Error("Only local demo adapters are configured. Set DEMO_MODE=true, CHAIN=mock, LLM=ondevice.");
  }
}
