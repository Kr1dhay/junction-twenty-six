import type { Metadata } from "next";
import "./globals.css";
export const metadata: Metadata = { title: "Edge-Care · Clinical workspace", description: "Anonymous referrals and single-use verification. Demonstration only.", robots: { index: false, follow: false } };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
