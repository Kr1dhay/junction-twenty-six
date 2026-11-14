import { cookies } from "next/headers";
import { ReferralDashboard } from "../components/referral-dashboard";
import { DemoEntry } from "../components/demo-entry";
import { validSession } from "../server/auth";
export const dynamic = "force-dynamic";
export default async function Home() {
  const cookieStore = await cookies();
  return validSession(cookieStore.get("edgecare_demo_session")?.value) ? <ReferralDashboard /> : <DemoEntry />;
}
