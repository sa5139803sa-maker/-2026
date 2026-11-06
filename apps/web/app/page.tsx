import { redirect } from "next/navigation";
import { getCurrentWebProfile } from "@/lib/auth/server";

export const dynamic = "force-dynamic";

export default async function HomePage() {
  const profile = await getCurrentWebProfile();
  if (!profile) redirect("/login");
  if (profile.must_change_password) redirect("/change-password");
  redirect(profile.role === "platform_admin" ? "/platform" : "/organization");
}