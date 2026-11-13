# AI Code Limits

Нативное macOS-приложение в строке меню: показывает остатки лимитов **Kimi Coding**, **OpenCode Go** и **Qwen Token Plan**.

В строке меню `K 80·95  G 90·96·100  Q 100` означает:

- `K` — окна Kimi Coding;
- `G` — 5 часов, неделя и месяц OpenCode Go;
- `Q` — окна Qwen Token Plan (сейчас у Individual это месяц);
- числа — процент оставшегося лимита.

В меню есть шкалы, время сброса и отдельные ошибки по каждому сервису. Обновление — раз в две минуты. Цвет становится оранжевым при остатке ≤20% и красным при ≤10%.

## Авторизация

Отдельный вход не нужен: приложение использует авторизацию CLI и браузерную сессию.

- **Kimi:** `/login` в Kimi Code CLI. Читается актуальный файл креденшелсов Kimi Code 2.4+: `$KIMI_CODE_HOME/credentials/kimi-code-env-*.json` (по умолчанию `~/.kimi-code/credentials/`), с fallback на старый путь `~/.kimi/credentials/kimi-code.json`. Истёкший OAuth-токен обновляется через тот же публичный OAuth client ID, что использует CLI; если в файле нет `expires_at`, обновление срабатывает при ответе 401. Можно переопределить токен через `KIMI_LIMITS_TOKEN` или `KIMI_API_KEY`. Показываются окна «5h» и «Month code».
- **OpenCode Go:** `/connect` в OpenCode. Приложение берёт ключ Go из хранилища OpenCode (`~/.local/share/opencode/opencode.db`) и вызывает `GET https://opencode.ai/zen/go/v1/usage`; ключ используется в памяти и не копируется в файлы приложения. Нужны OpenCode CLI и подключённая подписка Go. Показываются окна «5h», «Week» и «Month».
- **Qwen Token Plan:** у Token Plan **нет usage API по API-ключу** — ключ `sk-sp-` даёт доступ только к моделям. Остаток Credits читается через консольный шлюз `home.qwencloud.com` с cookie браузерной сессии (тот же контракт, что у дашборда). Приложение берёт Cookie-заголовок из `QWEN_CLOUD_COOKIE` или файла `~/.config/ai-code-limits/qwen-cloud-cookie` (одна строка, можно с префиксом `Cookie:`). Ключевой тикет `login_qwencloud_ticket` — HttpOnly и живёт ~30 дней, поэтому `document.cookie` из консоли не подходит. Способы получить заголовок:
  - скрипт `scripts/qwen-cookie.js` (код для browse/Playwright, вытаскивает и HttpOnly-cookie);
  - вручную: DevTools → Network → любой запрос к `home.qwencloud.com` → Request Headers → скопировать значение `Cookie:` целиком в файл.

  Показываются окна «5h», «Week», «Month» (какие вернёт API; у Individual сейчас только «Month») и тариф. Приложение не отправляет промпты и не расходует Credits.

Приложение запрашивает только usage API, не отправляет промпты и не расходует квоту. Это неофициальный проект, не связанный с Moonshot AI, OpenCode или QwenCloud; форматы API могут измениться.

## Сборка и установка

Нужны macOS 14+, Swift и установленные `kimi-code` / `opencode`.

```bash
./scripts/build-app.sh --install
```

Собирает `dist/AI Code Limits.app`, заменяет `/Applications/AI Code Limits.app` и запускает её. Без `--install` — только сборка. При установке убирается старое приложение `Coding Limits.app` (прежнее имя проекта).

## Проверка и диагностика

```bash
swift build
./.build/release/AICodeLimitsMenuBar --snapshot
./.build/release/AICodeLimitsMenuBar --raw
```

`--snapshot` печатает разобранные окна, `--raw` — ответы API. Токены и cookie в вывод не попадают.