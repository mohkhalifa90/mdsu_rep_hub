# MDSU Rep Hub

تطبيق واحد بكود واحد (Flutter) لاتحاد طلاب Mälardalen:

- **ممثل الطلاب (موبايل Android / iOS):** تسجيل الساعات بدل شيت الإكسل، إرسال التقرير آخر الترم، إرسال مواضيع الأجندة، متابعة القضايا، القنوات، لوحة الـ Tutoring.
- **مسؤول التعليم (ديسك توب Windows / macOS أو web):** استلام التقارير بالاسم وحساب المبلغ أوتوماتيك، تحميل ملف Excel للمرتبات، منشئ الأجندة، متابعة القضايا مع الترحيل والتصعيد التلقائي، القنوات والإعلانات مع تأكيد القراءة، إدارة الممثلين، الإعدادات.

التطبيق بيعرف دور المستخدم لوحده بعد تسجيل الدخول ويفتح الواجهة المناسبة.

```
lib/
  main.dart                 تسجيل الدخول + اختيار الواجهة حسب الدور
  src/data/                 الموديلات + كل الاتصال بقاعدة البيانات (repo.dart)
  src/rep/                  واجهة ممثل الطلاب
  src/officer/              لوحة تحكم مسؤول التعليم
  src/shared/               القنوات، الإشعارات، التنسيق، عناصر مشتركة
  src/push/                 إشعارات الموبايل (Firebase)
supabase/
  migrations/…_init.sql     قاعدة البيانات كاملة: الجداول، الصلاحيات، الحسابات، الأتمتة
  seed.sql                  بيانات البداية (المجالس والقنوات والترم الحالي)
  tests/                    42 اختبار للصلاحيات وسير العمل
  functions/send-push/      دالة بتبعت الإشعار للموبايل + اختباراتها
.github/workflows/build.yml بناء تلقائي لكل المنصات
```

---

## خطوات التشغيل

### 1) إنشاء مشروع Supabase (مرة واحدة)
1. ادخل [supabase.com](https://supabase.com) واعمل مشروع جديد. اختار المنطقة **EU North (Stockholm)** عشان البيانات تفضل في السويد.
2. من **SQL Editor** افتح ملف `supabase/migrations/20261111000000_init.sql`، انسخه كله واضغط **Run**.
3. بعده شغّل `supabase/seed.sql` بنفس الطريقة. عدّل أسماء المجالس فيه لتطابق مجالسكم الحقيقية قبل ما تشغله.
4. من **Database → Extensions** فعّل **pg_cron**، وبعدها شغّل السطر ده مرة واحدة، عشان التذكيرات والتصعيد يشتغلوا كل يوم الساعة 07:05 بتوقيت السويد:
   ```sql
   select cron.schedule('mdsu-daily-automations', '5 6 * * *', 'select public.run_automations()');
   ```

### 2) تسجيل الدخول بكود على الإيميل
1. من **Authentication → Providers** اتأكد إن **Email** شغال.
2. من **Authentication → Email Templates → Magic Link** حط الكود في الرسالة، مثلاً:
   ```html
   <h2>MDSU Rep Hub</h2>
   <p>Your sign-in code: <strong>{{ .Token }}</strong></p>
   ```
   كده الطالب بيستلم كود من 6 أرقام يكتبه في التطبيق، من غير باسورد ومن غير لينكات.

### 3) أول حساب لمسؤول التعليم
1. شغّل التطبيق (الخطوة 4) وسجّل دخول بإيميل مسؤول التعليم.
2. ارجع لـ **SQL Editor** في Supabase وشغّل:
   ```sql
   update public.profiles set role = 'officer', active = true where email = 'utbildning@mdsu.se';
   ```
3. أي ممثل جديد بيسجّل دخول بإيميل الطالب بتاعه وبيظهر لمسؤول التعليم في صفحة **Representatives** باللون الرمادي. مسؤول التعليم بيفعّله ويحدد البرنامج والمجالس والعضوية. **قبل التفعيل الحساب مش بيشوف أي حاجة** غير صفحة "في انتظار الموافقة".

### 4) تشغيل التطبيق على جهازك
محتاج تكون مسطّب [Flutter](https://docs.flutter.dev/get-started/install). من **Project Settings → API** في Supabase خد الـ **Project URL** والـ **anon public key**، وبعدين:

```bash
bash tool/setup_platforms.sh        # مرة واحدة: بيعمل فولدرات android/ios/windows/macos/web
flutter pub get
flutter run --dart-define=SUPABASE_URL=https://xxxx.supabase.co --dart-define=SUPABASE_ANON_KEY=eyJ...
```

### 5) البناء التلقائي على GitHub
1. ارفع المشروع على GitHub (ممكن يكون repo خاص).
2. من **Settings → Secrets and variables → Actions** ضيف سرّين: `SUPABASE_URL` و `SUPABASE_ANON_KEY`.
3. مع كل push هيشتغل الآتي:
   - اختبارات قاعدة البيانات الـ 42 واختبارات دالة الإشعارات.
   - فحص الكود.
   - بناء **APK للأندرويد** ونسخة **Windows** و **macOS** و **web**، تلاقيهم في تبويب **Actions → Artifacts** جاهزين للتحميل.
   - بناء iOS للتأكد إن الكود بيشتغل عليه. النشر على App Store محتاج حساب Apple Developer (99 دولار في السنة)، والنشر على Google Play محتاج رسوم 25 دولار مرة واحدة.

### 6) إشعارات الموبايل (والتطبيق مقفول)
التطبيق شغال من غير الخطوة دي، بس الإشعارات هتبان جوه التطبيق بس. عشان توصل على الموبايل زي رسايل واتساب:

**أ) Firebase (مجاني):**
1. ادخل [console.firebase.google.com](https://console.firebase.google.com) واعمل مشروع جديد.
2. ضيف تطبيق **Android** واكتب الـ package name: `se.mdsu.mdsu_rep_hub`. مش محتاج تنزّل ملف google-services.json.
3. ضيف تطبيق **iOS** واكتب الـ bundle ID: `se.mdsu.mdsuRepHub`.
4. من **Project settings → General** خد القيم دي وحطها في GitHub Secrets (أو في `--dart-define` لو بتشغّل على جهازك):
   | السر | منين |
   |---|---|
   | `FIREBASE_API_KEY` | Web API Key |
   | `FIREBASE_PROJECT_ID` | Project ID |
   | `FIREBASE_SENDER_ID` | Cloud Messaging → Sender ID |
   | `FIREBASE_ANDROID_APP_ID` | App ID بتاع تطبيق Android (بيبدأ بـ `1:`) |
   | `FIREBASE_IOS_APP_ID` | App ID بتاع تطبيق iOS |
   | `FIREBASE_IOS_BUNDLE_ID` | `se.mdsu.mdsuRepHub` |
5. من **Project settings → Service accounts** اضغط **Generate new private key**، وهينزل ملف JSON. **الملف ده سري، ما تبعتهوش لحد.**

**ب) دالة الإرسال على Supabase:**
1. سطّب [Supabase CLI](https://supabase.com/docs/guides/cli) وشغّل الأوامر دي:
   ```bash
   supabase login
   supabase link --project-ref <project-ref>
   supabase functions deploy send-push --no-verify-jwt
   supabase secrets set FIREBASE_SERVICE_ACCOUNT="$(cat service-account.json)" WEBHOOK_SECRET=<كلمة-سر-طويلة>
   ```
2. من **Database → Webhooks → Create a new hook**:
   - **Table:** `notifications`
   - **Events:** Insert
   - **Type:** Supabase Edge Functions → `send-push`
   - **HTTP Headers:** ضيف `x-webhook-secret` وقيمته نفس كلمة السر اللي حطيتها فوق.

**ج) الآيفون بس:** محتاج حساب Apple Developer. من [developer.apple.com](https://developer.apple.com) اعمل **APNs Key** وارفعه في Firebase من **Project settings → Cloud Messaging**. وبعدها في Xcode افتح `ios/Runner.xcworkspace` وضيف **Push Notifications** من **Signing & Capabilities**.

بعد كده أي إشعار في السيستم بيوصل على موبايل الممثل: موافقة على تقرير، إعلان جديد، تذكير بالأجندة، أو تذكير بتسجيل الساعات. ولو داس على الإشعار، التطبيق بيفتح على الصفحة الصح على طول.

---

## قواعد العمل (موجودة في قاعدة البيانات)
| القاعدة | التنفيذ |
|---|---|
| الأجر | 130 كرونة/ساعة = 65 لكل نص ساعة بدأت، على **إجمالي** الترم، للأعضاء بس (`pay_amount`) |
| تثبيت المبلغ | عند الموافقة يتسجل المبلغ، فتغيير السعر بعدين ما بيأثرش على التقارير المعتمدة |
| قفل التقرير | بعد Submit مفيش تعديل غير لو مسؤول التعليم رجّعه (`guard_time_entry`) |
| التأخير | التقرير المتأخر بيتعلّم عليه `is_late` |
| القضايا | أي قضية مالهاش رد بتظهر لوحدها في أجندة الاجتماع الجاي لنفس المجلس، وبتتصعّد بعد عدد اجتماعات بتحدده (الافتراضي 2) |
| الأجندة | التذكير بيتبعت قبل الاجتماع بـ 7 أيام، وآخر ميعاد لإرسال المواضيع قبل الاجتماع بيومين. الرقمين بيتغيّروا من صفحة الإعدادات |
| تصدير المرتبات | ملف Excel فيه شيتين: Payroll (ملخص لكل ممثل وإجمالي المبلغ) و Entries (كل نشاط اتسجّل، للتوثيق) |
| الخصوصية | الممثل يشوف بياناته بس، الرقم الشخصي في جدول منفصل، وإيميل الممثل مش بيظهر للممثلين التانيين إلا لو وافق |
| الحسابات الجديدة | مش بتشوف أي حاجة لحد ما مسؤول التعليم يفعّلها |

## اختبار قاعدة البيانات محلياً (اختياري)
```bash
psql -f supabase/tests/stub_supabase.sql      # بديل مبسط لـ auth بتاع Supabase
psql -f supabase/migrations/20261111000000_init.sql
psql -f supabase/seed.sql
psql -f supabase/tests/workflow_test.sql      # لازم يطلع: failures = 0
deno test --allow-net --allow-env supabase/functions/send-push/index.test.ts
```

## المرحلة الجاية (مش موجودة في النسخة دي)
- **الدخول بحساب Microsoft (MDU):** محتاج تسجيل تطبيق في Azure بموافقة الـ IT في الجامعة.
- **إشعارات على الديسك توب وعلى نسخة الويب:** دلوقتي مسؤول التعليم بيشوف الإشعارات جوه التطبيق بس.
- **ترجمة الواجهة للسويدي والعربي.**
