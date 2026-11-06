import type { Metadata } from "next";
import { AccountConsole } from "@/components/account-console";
import { requireWebRole } from "@/lib/auth/server";

export const metadata: Metadata = { title: "إدارة المؤسسة" };
export const dynamic = "force-dynamic";
export const revalidate = 0;

export default async function OrganizationPage() {
  const profile = await requireWebRole("manager");

  return (
    <>
      <header className="topbar">
        <div>
          <h1>لوحة إدارة المؤسسة</h1>
          <p>إدارة حسابات العاملين ضمن مؤسستك وصلاحياتهم.</p>
        </div>
        <div className="topbar-actions"><span className="badge">مدير المؤسسة</span></div>
      </header>
      <AccountConsole mode="organization" organizationId={profile.organization_id ?? undefined} />
    </>
  );
}