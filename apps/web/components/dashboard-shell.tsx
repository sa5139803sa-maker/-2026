import Link from "next/link";
import { Droplets, LayoutDashboard, ShieldCheck, UsersRound, Globe2 } from "lucide-react";
import { LogoutButton } from "@/components/logout-button";

type DashboardShellProps = {
  role: "platform_admin" | "manager";
  displayName: string;
  children: React.ReactNode;
};

export function DashboardShell({ role, displayName, children }: DashboardShellProps) {
  const isPlatform = role === "platform_admin";
  const title = isPlatform ? "إدارة المنصة" : "إدارة المؤسسة";

  return (
    <div className="web-shell">
      <aside className="sidebar">
        <Link href={isPlatform ? "/platform" : "/organization"} className="brand" aria-label="إدارة المياه">
          <span className="brand-mark"><Droplets size={23} /></span>
          <span className="brand-copy">
            <span className="brand-name">إدارة المياه</span>
            <span className="brand-en">WATER MANAGEMENT</span>
          </span>
        </Link>

        <nav aria-label="التنقل الرئيسي">
          <div className="side-label">مساحة العمل</div>
          <Link className="side-link active" href={isPlatform ? "/platform" : "/organization"}>
            <LayoutDashboard size={18} />
            <span>لوحة التحكم</span>
          </Link>
          <Link className="side-link" href="/portal">
            <Globe2 size={18} />
            <span>بوابة المشترك العامة</span>
          </Link>
          {isPlatform ? (
            <div className="side-link" aria-label="صلاحيات مدير المنصة">
              <ShieldCheck size={18} />
              <span>صلاحيات المنصة</span>
            </div>
          ) : (
            <div className="side-link" aria-label="حسابات الموظفين">
              <UsersRound size={18} />
              <span>حسابات الموظفين</span>
            </div>
          )}
        </nav>

        <div className="sidebar-foot">
          <div className="sidebar-user">
            <strong>{displayName}</strong>
            <span>{title}</span>
          </div>
          <LogoutButton />
        </div>
      </aside>

      <main className="main-area">
        <div className="content-width">{children}</div>
      </main>
    </div>
  );
}