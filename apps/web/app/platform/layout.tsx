import { DashboardShell } from "@/components/dashboard-shell";
import { requireWebRole } from "@/lib/auth/server";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export default async function PlatformLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  const profile = await requireWebRole("platform_admin");

  return (
    <DashboardShell role="platform_admin" displayName={profile.display_name}>
      {children}
    </DashboardShell>
  );
}