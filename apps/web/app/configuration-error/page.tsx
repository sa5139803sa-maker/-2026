export default function ConfigurationErrorPage() {
  return (
    <main className="page-center">
      <section className="auth-card">
        <h1 style={{ fontSize: 21 }}>إعدادات الاتصال غير مكتملة</h1>
        <p className="muted small" style={{ lineHeight: 2 }}>
          لم تُضبط متغيرات اتصال Supabase العامة لتطبيق الويب. أضف
          NEXT_PUBLIC_SUPABASE_URL وNEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY إلى بيئة التشغيل،
          ثم أعد النشر. لا تضع مفتاح service_role في أي متغير NEXT_PUBLIC.
        </p>
      </section>
    </main>
  );
}