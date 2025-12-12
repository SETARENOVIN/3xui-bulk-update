3xui-bulk-update

اسکریپت تعاملی برای تمدید انقضا و/یا افزایش حجم کاربران داخل یک Inbound در پنل 3x-ui / 3xui، همراه با فیلترها و نمایش Progress + ETA.


---

دانلود و اجرا

اجرای مستقیم (تک‌خطی)

bash <(curl -fsSL "https://raw.githubusercontent.com/SETARENOVIN/3xui-bulk-update/refs/heads/main/3xui-bulk-update.sh")

دانلود، chmod و اجرا

curl -fsSL "https://raw.githubusercontent.com/SETARENOVIN/3xui-bulk-update/refs/heads/main/3xui-bulk-update.sh" -o 3xui-bulk-update.sh \
&& chmod +x 3xui-bulk-update.sh \
&& ./3xui-bulk-update.sh


---

راهنمای استفاده

1) وارد کردن PANEL_URL

در ابتدای اجرا از شما آدرس پنل را می‌خواهد. حتماً Base URL را بدهید (بدون /login و بدون /panel/...).

مثال:

https://panel.example.com:2053/path

2) ورود به پنل

USERNAME و PASSWORD را وارد کنید.

اگر 2FA دارید: HAS_2FA = y و سپس TWO_FACTOR_CODE را وارد کنید.

اگر SSL شما self-signed است: INSECURE_TLS = y


3) انتخاب عملیات

منوی سه‌خطی:

1. EXPIRY_ONLY: افزایش انقضا بر اساس روز


2. TRAFFIC_ONLY: افزایش حجم بر اساس GB


3. BOTH: انجام هر دو



سپس مقدارها را وارد می‌کنید:

ADD_DAYS (مثلاً 1)

ADD_GB (مثلاً 10)


رفتار برای کاربرهایی که محدودیت ندارند

اگر expiryTime = 0 (بدون انقضا):

NOEXP_BEHAVIOR = skip یعنی کاری نکند

NOEXP_BEHAVIOR = setFromNow یعنی از الان + تعداد روز تعیین کند


اگر totalGB = 0 (بدون محدودیت حجم):

NOQUOTA_BEHAVIOR = skip یعنی کاری نکند

NOQUOTA_BEHAVIOR = setLimit یعنی حجم را برابر مقدار اضافه‌شده ست کند



4) فیلترها

ONLY_ENABLED:

y فقط کاربران فعال

n همه کاربران


EXPIRE_WITHIN_DAYS:

0 یعنی همه کاربران

1 یعنی فقط کسانی که تا ۱ روز آینده منقضی می‌شوند


EMAIL_REGEX:

خالی = همه

مثال‌ها:

vip  (هر ایمیلی که vip داشته باشد)

@gmail\.com$ (فقط جیمیل)

^(vip|pro)- (ایمیل‌هایی که با vip- یا pro- شروع می‌شوند)





---

خروجی برنامه

در طول اجرا فقط یک خط به‌روز می‌شود:

درصد انجام شده

تعداد پردازش شده/کل

تعداد OK/FAIL/SKIP

زمان باقی‌مانده (ETA)


در پایان هم خلاصه‌ی نهایی نمایش داده می‌شود و اگر خطا وجود داشته باشد، چند نمونه خطا چاپ می‌شود.


---

خطاهای رایج

database is locked

این خطا معمولاً به خاطر قفل شدن دیتابیس SQLite در لحظه‌ی نوشتن رخ می‌دهد (مثلاً همزمان پنل باز است یا درخواست‌های متعدد پشت سر هم می‌آیند).
اسکریپت خودش چند بار با تاخیر افزایشی (backoff) تلاش می‌کند.

پیشنهاد:

اسکریپت را زمانی اجرا کنید که پنل کمتر در حال استفاده است.

