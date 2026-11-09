import { redirect } from "next/navigation";
import { PasswordChangeForm } from "@/components/password-change-form";
import { getCurrentWebProfile } from "@/lib/auth/server";

export const metadata = { title: "تغيير كلمة المرور" };
export const dynamic = "force-dynamic";
export const revalidate = 0;

export default async function ChangePasswordPage() {
  const profile = await getCurrentWebProfile();
  if (!profile) redirect("/login");
  if (!profile.must_change_password) {
    redirect(profile.role === "platform_admin" ? "/platform" : "/organization");
  }

  return (
    <main className="page-center">
      <PasswordChangeForm />
    </main>
  );
}