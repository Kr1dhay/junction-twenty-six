import { cookies } from "next/headers";
import { ReferralDashboard } from "../components/referral-dashboard";
import { DemoLogin } from "../components/demo-login";
import { validSession } from "../server/auth";
export const dynamic = "force-dynamic";
export default async function Home() {
  const cookieStore = await cookies();
  return validSession(cookieStore.get("edgecare_demo_session")?.value) ? <ReferralDashboard /> : <DemoLogin requiresToken={Boolean(process.env.EDGECARE_CLINICIAN_TOKEN)} />;
}
