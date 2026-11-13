// Извлекает cookie сессии Qwen Cloud (включая HttpOnly) и сохраняет Cookie-заголовок
// для приложения AI Code Limits.
//
// ПОЧЕМУ НЕ document.cookie: ключевой тикет login_qwencloud_ticket — HttpOnly,
// сниппет в консоли страницы его не видит. Нужен доступ уровня CDP/Playwright.
//
// КАК ЗАПУСТИТЬ: этот файл — готовый код для инструмента browse (execute),
// который подключён к вашему реальному Chrome с живой сессией Qwen Cloud.
// Передайте содержимое между маркерами BEGIN/END в browse.execute({ code: … }).
// Перед запуском войдите на https://home.qwencloud.com в том же браузере.
//
// Скрипт пишет заголовок во временный файл (browse разрешает запись только в
// свои корни) и возвращает его путь. Затем перенесите файл в конфиг:
//
//   mkdir -p ~/.config/ai-code-limits && chmod 700 ~/.config/ai-code-limits
//   mv "<путь из вывода>" ~/.config/ai-code-limits/qwen-cloud-cookie
//   chmod 600 ~/.config/ai-code-limits/qwen-cloud-cookie
//
// Альтернатива без скрипта: DevTools → Network → любой запрос к home.qwencloud.com
// → Request Headers → скопировать значение `Cookie:` целиком в тот же файл.

// BEGIN browse.execute code
const dashboard = "https://home.qwencloud.com/billing/subscription/token-plan-individual";
await page.goto(dashboard, { waitUntil: "domcontentloaded", timeout: 45000 });
await page.waitForTimeout(2500);

// Проверяем, что сессия жива (без вывода чувствительных значений).
const login = await page.evaluate(async () => {
  const res = await fetch("/tool/user/info.json", { credentials: "include" });
  const j = await res.json().catch(() => null);
  return { status: res.status, success: j?.successResponse === true };
});
if (!login.success) {
  return { error: "Qwen Cloud session is not logged in. Sign in at home.qwencloud.com and re-run.", login };
}

// context.cookies отдаёт и HttpOnly-cookie для обоих хостов (dashboard + API-шлюз).
const cookies = await context.cookies([
  "https://home.qwencloud.com",
  "https://cs-data.qwencloud.com",
]);
const header = cookies.map((c) => `${c.name}=${c.value}`).join("; ");
const target = files.path("qwen-cloud-cookie");
await files.write(target, header + "\n");
return { written: target, cookieCount: cookies.length, headerBytes: header.length };
// END browse.execute code