import type { Metadata } from "next";
import Link from "next/link";
import { Droplets, ShieldCheck } from "lucide-react";
import { SubscriberLookupForm } from "@/components/subscriber-lookup-form";

export const metadata: Metadata = { title: "بوابة المشترك" };
export const dynamic = "force-dynamic";
export const revalidate = 0;

export default function SubscriberPortalPage() {
  return (
    <main className="page-center">
      <section className="auth-card portal-card">
        <div className="brand">
          <span className="brand-mark"><Droplets size={23} /></span>
          <div>
            <div className="brand-name">إدارة المياه</div>
            <div className="brand-en">SUBSCRIBER PORTAL</div>
          </div>
        </div>
        <h1>بوابة المشترك</h1>
        <p>
          أدخل رقم المشترك المكوّن من ست خانات ورقم الهاتف المسجل لدى المؤسسة
          لعرض بيانات اشتراكك الأساسية.
        </p>

        <div className="notice portal-intro-note">
          <ShieldCheck size={17} />
          <span>التحقق يتم بمطابقة الرقمين فقط، دون OTP أو رسائل نصية.</span>
        </div>

        <SubscriberLookupForm />

        <div className="footer-note">
          لا يحتاج المشترك إلى إنشاء حساب أو كلمة مرور. لا تظهر بيانات الاشتراك إلا عند تطابق الرقم والهاتف مع سجل نشط.
        </div>
        <div style={{ marginTop: 16, textAlign: "center" }}>
          <Link className="small muted" href="/login">دخول الإدارة</Link>
        </div>
      </section>
    </main>
  );
}
