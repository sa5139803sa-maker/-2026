"use client";

import { useState, type FormEvent } from "react";
import { Search, ShieldCheck, UserRound, RefreshCw } from "lucide-react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

type SubscriberResult = {
  subscriber_number: string;
  full_name: string;
  pump_name: string | null;
  pump_code: string | null;
  phone_last4: string;
};

type LookupResponse = {
  found?: boolean;
  subscriber?: SubscriberResult;
  error?: string;
};

function toLatinDigits(value: string): string {
  const arabic = "٠١٢٣٤٥٦٧٨٩";
  const persian = "۰۱۲۳۴۵۶۷۸۹";
  return value.replace(/[٠-٩۰-۹]/g, (digit) => {
    const index = arabic.indexOf(digit);
    return String(index >= 0 ? index : persian.indexOf(digit));
  });
}

export function SubscriberLookupForm() {
  const [subscriberNumber, setSubscriberNumber] = useState("");
  const [phone, setPhone] = useState("");
  const [result, setResult] = useState<SubscriberResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setResult(null);
    setError(null);

    const normalizedNumber = toLatinDigits(subscriberNumber.trim());
    const normalizedPhone = phone.trim();

    if (!/^\d{6}$/.test(normalizedNumber)) {
      setError("أدخل رقم المشترك المكوّن من 6 خانات.");
      return;
    }
    if (normalizedPhone.length < 7 || normalizedPhone.length > 32) {
      setError("أدخل رقم الهاتف المسجل لدى المؤسسة.");
      return;
    }

    setBusy(true);
    try {
      const { data, error: requestError } =
        await createSupabaseBrowserClient().functions.invoke<LookupResponse>(
          "subscriber-portal",
          {
            body: {
              subscriber_number: normalizedNumber,
              phone: normalizedPhone,
            },
          },
        );

      if (requestError) {
        const status = (requestError as { context?: Response }).context?.status;
        if (status === 429) {
          throw new Error("تجاوزت عدد محاولات البحث المسموح. حاول بعد قليل.");
        }
        throw new Error("تعذر الاتصال بخدمة الاستعلام. حاول مجددًا.");
      }

      if (!data?.found || !data.subscriber) {
        throw new Error("لم نعثر على اشتراك يطابق البيانات المدخلة.");
      }

      setResult(data.subscriber);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "تعذر تنفيذ الاستعلام.");
    } finally {
      setBusy(false);
    }
  }

  function reset() {
    setResult(null);
    setError(null);
    setSubscriberNumber("");
    setPhone("");
  }

  return (
    <div className="portal-lookup">
      <form className="portal-search" onSubmit={(event) => void submit(event)}>
        <label className="field">
          <span>رقم المشترك — 6 خانات</span>
          <input
            value={subscriberNumber}
            onChange={(event) =>
              setSubscriberNumber(toLatinDigits(event.target.value).replace(/\D/g, "").slice(0, 6))
            }
            inputMode="numeric"
            autoComplete="off"
            maxLength={6}
            pattern="[0-9]{6}"
            placeholder="مثال: 482731"
            required
            dir="ltr"
          />
        </label>

        <label className="field">
          <span>رقم الهاتف المسجل للاشتراك</span>
          <input
            value={phone}
            onChange={(event) => setPhone(event.target.value.slice(0, 32))}
            type="tel"
            inputMode="tel"
            autoComplete="tel"
            maxLength={32}
            placeholder="0591234567"
            required
            dir="ltr"
          />
        </label>

        <button className="primary-button full-width" type="submit" disabled={busy}>
          {busy ? <RefreshCw size={16} className="spin" /> : <Search size={16} />}
          {busy ? "جارٍ التحقق..." : "الاستعلام عن الاشتراك"}
        </button>
      </form>

      <p className="portal-privacy">
        <ShieldCheck size={15} />
        تتم المطابقة باستخدام الرقمين فقط. لا يوجد OTP أو رسائل تحقق.
      </p>

      {error ? <div className="error" role="alert">{error}</div> : null}

      {result ? (
        <section className="surface-card portal-result" aria-live="polite">
          <div className="portal-result-heading">
            <span className="badge" style={{ background: "var(--success-bg)", color: "#146C43" }}>تم التحقق</span>
            <span className="small muted">بيانات الاشتراك الأساسية</span>
          </div>

          <div className="portal-result-name">
            <span className="stat-icon"><UserRound size={21} /></span>
            <div>
              <strong>{result.full_name}</strong>
              <small>رقم المشترك: <b dir="ltr">{result.subscriber_number}</b></small>
            </div>
          </div>

          <div className="portal-result-grid">
            <div>
              <small>الغطاس المرتبط</small>
              <strong>{result.pump_name ?? "غير محدد"}</strong>
              {result.pump_code ? <span>الرمز: {result.pump_code}</span> : null}
            </div>
            <div>
              <small>الهاتف المسجل</small>
              <strong dir="ltr">•••• {result.phone_last4}</strong>
            </div>
          </div>

          <div className="notice portal-limited-note">
            تعرض البوابة حاليًا بيانات الاشتراك الأساسية. تفاصيل التعبئات والمستحقات ستضاف عند تجهيز وحدات السجلات المالية والتشغيلية.
          </div>
          <button className="ghost-button full-width" type="button" onClick={reset}>
            استعلام جديد
          </button>
        </section>
      ) : null}
    </div>
  );
}
