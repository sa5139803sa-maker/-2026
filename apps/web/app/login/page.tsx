import type { Metadata } from "next";
import { LoginForm } from "@/components/login-form";
import { Droplets } from "lucide-react";

export const metadata: Metadata = { title: "تسجيل الدخول" };

export default function LoginPage() {
  return (
    <main className="page-center">
      <section className="auth-card">
        <header className="auth-head">
          <div className="brand">
            <span className="brand-mark"><Droplets size={23} /></span>
            <div>
              <div className="brand-name">إدارة المياه</div>
              <div className="brand-en">WATER MANAGEMENT</div>
            </div>
          </div>
          <h1>مرحبًا بعودتك</h1>
          <p>سجّل الدخول إلى مساحة الإدارة المخصصة لدورك.</p>
        </header>
        <LoginForm />
        <footer className="auth-foot">
          لوحة ويب مستقلة لإدارة المنصة والمؤسسات. العاملون الميدانيون يستخدمون تطبيق Android.
        </footer>
      </section>
    </main>
  );
}