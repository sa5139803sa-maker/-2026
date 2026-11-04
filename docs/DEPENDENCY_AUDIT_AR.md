# تقرير تدقيق اعتماديات npm وخطة المعالجة

**تاريخ الفحص:** 2026-11-04  
**المرجع:** GitHub Actions Run #44 وRun #2 في تجربة الإصلاح المعزولة.  
**الفرع الأساسي:** `main`، Expo SDK 57.

## 1. نتيجة التدقيق قبل الإصلاح

سجل Run #44 بعد `npm ci` الأرقام التالية:

| المستوى | عدد النتائج |
|---|---:|
| حرجة | 1 |
| عالية | 10 |
| متوسطة | 13 |
| منخفضة | 2 |
| **الإجمالي** | **26** |

## 2. نتيجة تجربة الإصلاح المتوافقة مع SemVer

أنشئت تجربة مستقلة باستخدام:

```bash
npm audit fix --package-lock-only --ignore-scripts
npm ci
npm test
npm run typecheck
npm run build:web
```

لم يستخدم الأمر `--force`، ولم يُطلب ترقية Expo أو Expo Router إلى إصدار رئيسي. أُنتج ملف `package-lock.json` مرشح، واختبر التثبيت والاختبارات وفحص TypeScript وتصدير الويب بنجاح في GitHub Actions Run #2.

| المستوى | قبل | بعد التجربة |
|---|---:|---:|
| حرجة | 1 | 0 |
| عالية | 10 | 5 |
| متوسطة | 13 | 10 |
| منخفضة | 2 | 2 |
| **الإجمالي** | **26** | **17** |

التجربة أزالت الثغرة الحرجة وخفّضت إجمالي النتائج بمقدار 9. بعد نجاح الفحص، تم دفع المرشح إلى فرع `chore/npm-audit-safe-lockfile` في commit `128da9a9b2bec16859e251f87da2309b5b733f1d`. من بين الحزم التي ظهرت بعد التجربة بإصدارات محدثة: `@xmldom/xmldom 0.9.12`، `node-forge 1.4.3`، `shell-quote 1.12.0`، `ws 8.22.1`، `picomatch 4.0.7`، `yaml 2.9.1`، و`@react-navigation/core 7.24.0`.

## 3. النتائج المتبقية التي لا يحلها التحديث المتوافق

بعد التجربة بقيت 17 نتيجة:

- **عالية:** `@expo/cli`، `decode-uri-component`، `expo-router`، `query-string`، `zod`.
- **متوسطة:** مكونات من سلسلة Expo مثل `@expo/config` و`@expo/config-plugins` و`@expo/fingerprint` و`@expo/metro-config` و`@expo/prebuild-config`، إضافة إلى `expo` و`expo-splash-screen` و`glob` و`minimatch`.
- **منخفضة:** `deepmerge` و`@expo/local-build-cache-provider`.

تربط بيانات npm حل معظم النتائج المتعلقة بـExpo بالترقية إلى `expo 58.0.23)، وتربط `expo-router` و`decode-uri-component/query-string` بالترقية إلى `expo-router 58.0.30`. هذه تغييرات رئيسية بالنسبة لخط المشروع الحالي (SDK 57)، ولذلك يجب تنفيذها كترحيل SDK مستقل، لا كتحديث عابر للـlockfile.

## 4. قرار الإصلاح

1. قبول تجربة الإصلاح المتوافقة كمرشح منفصل؛ لا يُدمج إلى `main` إلا بعد commit تلقائي إلى فرع المعالجة ونجاح CI على Pull Request.
2. عدم استخدام `npm audit fix --force` على `main`.
3. عدم اعتبار خفض العدد إلى 17 إغلاقًا أمنيًا كاملًا؛ يبقى المشروع بحاجة إلى معالجة النتائج العالية والمتوسطة.
4. إعداد ترحيل Expo SDK 58 مستقلًا: مواءمة حزم Expo وRouter وSplash Screen، تشغيل أداة فحص توافق Expo، اختبار Android وWeb وAuth والتوجيه، ثم مراجعة أي تغييرات API.
5. الاحتفاظ بتقرير `npm audit` الناتج عن كل تشغيل كأثر قابل للمراجعة.

## 5. حدود هذا التقرير

التقرير يعكس نتائج قاعدة البيانات الأمنية في وقت الفحص، وقد تتغير النتائج عند صدور إصدارات جديدة. لا يثبت التقرير قابلية استغلال كل ثغرة داخل مسارات التطبيق، ولا يُعد تحليلًا ساكنًا كاملًا لكل تبعيات الإنتاج. يجب تكرار الفحص قبل كل إصدار.

## 6. حالة المرشح في المستودع

- **الفرع:** `chore/npm-audit-safe-lockfile`.
- **Commit lockfile:** `128da9a9b2bec16859e251f87da2309b5b733f1d`.
- **GitHub Actions:** [Safe npm lockfile remediation Run #1](https://github.com/sa5139803sa-maker/-2026/actions/runs/41860812973) — success.
- **خطوات النجاح:** npm ci قبل الإصلاح، npm audit fix على lockfile فقط، npm ci بعد الإصلاح، تقرير audit، unit tests، TypeScript، web export، ثم commit/push.
- **الملفات المتغيرة في مرشح الإصلاح:** `package-lock.json` فقط؛ لا يوجد تعديل على `package.json` أو نسخ Expo المباشرة.
- **الحالة:** مرشح جاهز للمراجعة عبر Pull Request؛ لم يدمج في `main` بعد.


## 7. فحص توافق Expo قبل قبول مرشح lockfile

أضيف إلى سير `.github/workflows/dependency-safe-lockfile.yml` الأمر `npx expo install --check` بعد `npm ci` على lockfile المرشح. الهدف التأكد من أن التحديثات الانتقالية لم تجعل حزم Expo غير متوافقة مع SDK 57. كما أظهر فحص lockfile أن تحديث `xcode` من 3 إلى 4 مرتبط بتحديث `@expo/config-plugins 57.0.11` الذي يعلن `xcode: ^4.0.0` صراحةً. لا يُقبل المرشح حتى يمر الفحص الجديد واختبارات CI المطلوبة.

**حالة PR CI:** Quality run `41861656444` على PR #1 انتهى بـ`action_required` ولم ينشئ jobs؛ لذلك تجربة Safe lockfile remediation الناجحة على حدث push لا تُغني عن تنفيذ PR CI. يلزم موافقة التشغيل في GitHub ثم نجاح الفحوص على رأس طلب الدمج.
