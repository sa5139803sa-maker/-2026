# خطة ترحيل Expo SDK 57 إلى SDK 58

**الحالة:** خطة معتمدة للتنفيذ كمرحلة مستقلة؛ لم يبدأ تغيير إصدارات Expo في هذا المستودع.  
**تاريخ إعداد الخطة:** 2026-11-04.

## 1. خط الأساس الحالي

من ملفات المشروع في الفرع الأساسي:

| الحزمة | النسخة/النطاق الحالي |
|---|---|
| Expo | `~57.0.30` |
| Expo Router | `~57.0.28` في `package.json` (ويثبت lockfile أحدث patch ضمن النطاق) |
| React Native | `0.86.3` |
| React | `19.2.3` |
| Expo Splash Screen | `~57.0.10` |
| Node في CI | `24` |
| Web output | `single` محدد صراحة في `app.json` |

## 2. أسباب الترحيل

تدقيق npm بعد الإصلاحات المتوافقة مع SemVer ما زال يعرض ثغرات عالية ومتوسطة ضمن سلسلة Expo وExpo Router. أظهر سجل npm أن الإصدارات المصححة المطلوبة تشمل `expo 58.0.23` و`expo-router 58.0.30`، وهي ترقية SDK رئيسية لا يجوز إدخالها ضمن تعديل lockfile فقط.

وفق جدول Expo SDK:
- SDK 58 يرتبط بـ React Native 0.88 وReact 19.3.0.
- الحد الأدنى المعلن لـ Node هو 22.13.x؛ CI يستخدم Node 24.
- Android compile SDK 37 وtarget SDK 36.

المراجع الرسمية:
- [دليل الترقية إلى Expo SDK 58](https://expo.dev/blog/how-to-upgrade-to-sdk-58)
- [وثائق الترقية العامة](https://docs.expo.dev/workflow/upgrading-expo-sdk-walkthrough/)
- [Expo SDK 58 release notes](https://expo.dev/changelog/sdk-58)
- [SDK 57 إلى 58 — Expo Router migration](https://docs.expo.dev/router/migrate/sdk-57-to-58/)
- [جدول توافق إصدارات SDK](https://docs.expo.dev/versions/latest/)

## 3. تغييرات التوافق التي يجب فحصها

### React Native وTypeScript
- الترقية من RN 0.86 إلى 0.88.
- SDK 58 يجعل Strict TypeScript API افتراضيًا؛ يجب معالجة deep imports من `react-native/Libraries/*` إن وجدت.
- مراجعة APIs المحذوفة، ومنها `InteractionManager` وroot `Touchable` وبعض خصائص Modal وStatusBar.
- تشغيل typecheck مبكرًا بعد ترقية الاعتماديات.

### Expo Router
- بنية حالة التنقل ونواة الربط مع navigators أعيد تنظيمها.
- أي استخدام لـ`expo-router/react-navigation` أو custom navigators أو قراءة navigation state يحتاج مراجعة منفصلة.
- استيراد Native Tabs غير المستقر تغير مساره إلى `expo-router/native-tabs`.
- async routes على الويب مفعّلة افتراضيًا في SDK 58؛ يمكن تعطيلها من plugin عند الحاجة إلى سلوك متزامن.
- يجب مراجعة مخرجات الويب وملفات metadata والتحميل المتقطع للصفحات.

### Web output — قرار مهم للمشروع

المشروع يحدد حاليًا `web.output: "single"` صراحة. هذا يعني SPA بملف `index.html` واحد، وهو سلوك يجب الحفاظ عليه أثناء ترحيل SDK ما لم يُعتمد نشر مختلف.

لا تزل القيمة أو تتركها غير محددة بلا مراجعة؛ SDK 58 يغير سلوك server output في القوالب الجديدة، كما أن `static` و`server` يختلفان عن `single`. قرار التحويل إلى static أو server يحتاج تحديد منصة الاستضافة والبوابة المستقبلية أولًا.

## 4. خطة التنفيذ المقترحة

1. إنشاء فرع مستقل باسم `upgrade/expo-sdk-58` انطلاقًا من `main` بعد دمج تحديثات lockfile الآمنة.
2. تحديث حزمة Expo الرئيسية إلى نطاق SDK 58.
3. تشغيل `npx expo install --fix` لمواءمة حزم Expo وReact Native وReact والحزم الأصلية.
4. تشغيل `npx expo-doctor` و`npx expo install --check`.
5. معالجة أخطاء TypeScript وRouter، مع مراجعة web output والحفاظ على `single` إلى أن يُعتمد قرار تغيير الاستضافة.
6. تشغيل الاختبارات الحالية وCI، وإضافة اختبار للتحميل المباشر للمسارات وعودة زر الرجوع والتنقل بين التبويبات.
7. إنشاء Development Build واختبار Android فعليًا، لا الاكتفاء بتصدير الويب.
8. اختبار تسجيل الدخول والخروج واستعادة الجلسة وRoleGate وتسجيل المؤسسة.
9. إعادة `npm audit` وتوثيق قائمة الثغرات النهائية.
10. فتح Pull Request مستقل، وعدم الدمج حتى نجاح Android وWeb والمصادقة والصلاحيات.

## 5. بوابة القبول

- `npm ci` ينجح من lockfile نظيف.
- `npm test` ينجح.
- `npm run typecheck` ينجح مع strict types الجديدة.
- `npm run build:web` ينجح مع `web.output: "single"` دون تغيير غير مقصود في نوع الخرج.
- `npx expo-doctor` لا يظهر مشاكل توافق غير محلولة.
- Development Build على Android يعمل مع تسجيل الدخول والتنقل RTL.
- لا تتراجع حواجز الأدوار أو المصادقة.
- نتائج npm audit تنخفض أو تُوثق أي نتائج متبقية بسبب package آخر.

**قاعدة:** لا تخلط إصلاحات أمنية lockfile متوافقة مع SemVer مع ترحيل SDK رئيسي. كل واحد له فرع واختبارات وقرار قبول مستقل.
