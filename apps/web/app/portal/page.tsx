import type { Metadata } from "next";
import Link from "next/link";
import { Droplets, ShieldCheck } from "lucide-react";

export const metadata: Metadata = { title: "بوابة المشترك" };

export default function SubscriberPortalPage() {
  return (
    <main className="page-center">
      <section className="auth-card portal-card">
        <div className="brand">
          <span className="brand-mark"><Droplets size={23} /></span>
          <div><div className="brand-name">إدارة المياه</div><div className="brand-en">SUBSCRIBER PORTAL</div></div>
        </div>
        <h1>بوابة المشترك</h1>
        <p>
          ستتيح لك البوابة الاستعلام عن اشتراكك ومراجعة بياناتك بعد إدخال رقم الاشتراك،
          مع التحقق من ملكية رقم الهاتف قبل إظهار التفاصيل المالية أو الشخصية.
        </p>

        <div className="notice" style={{ display: "flex", gap: 9, alignItems: "flex-start" }}>
          <ShieldCheck size={18} style={{ flexShrink: 0, marginTop: 2 }} />
          <span>
            خدمة الاستعلام غير مفعّلة بعد. لن نبحث في قاعدة بيانات المشتركين قبل تجهيز
            رقم الاشتراك الفريد والتحقق الإضافي ومحددات المحاولات ومنع تعداد السجلات.
          </span>
        </div>

        <div className="portal-search">
          <label className="field">
            <span>رقم الاشتراك</span>
            <input disabled placeholder="سيظهر حقل البحث عند تفعيل الخدمة" />
          </label>
          <button className="primary-button full-width" type="button" disabled>
            الاستعلام عن الاشتراك
          </button>
        </div>

        <div className="footer-note">
          لا يحتاج المشترك إلى حساب مستخدم أو كلمة مرور. هذه البوابة لا تنشئ حسابًا في نظام العاملين.
        </div>
        <div style={{ marginTop: 16, textAlign: "center" }}>
          <Link className="small muted" href="/login">دخول الإدارة</Link>
        </div>
      </section>
    </main>
  );
}