import { DashboardShell } from "@/components/dashboard-shell";
import { requireWebRole } from "@/lib/auth/server";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export default async function OrganizationLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  const profile = await requireWebRole("manager");

  return (
    <DashboardShell role="manager" displayName={profile.display_name}>
      {children}
    </DashboardShell>
  );
}