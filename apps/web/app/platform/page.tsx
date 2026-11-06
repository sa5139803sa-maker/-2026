import type { Metadata } from "next";
import { AccountConsole } from "@/components/account-console";
import { requireWebRole } from "@/lib/auth/server";

export const metadata: Metadata = { title: "إدارة المنصة" };
export const dynamic = "force-dynamic";
export const revalidate = 0;

export default async function PlatformPage() {
  await requireWebRole("platform_admin");

  return (
    <>
      <header className="topbar">
        <div>
          <h1>لوحة إدارة المنصة</h1>
          <p>إدارة المؤسسات وحساباتها وحدود الاستخدام من نطاق المنصة.</p>
        </div>
        <div className="topbar-actions"><span className="badge">مدير المنصة</span></div>
      </header>
      <AccountConsole mode="platform" />
    </>
  );
}