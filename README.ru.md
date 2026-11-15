# hermes-secure-deploy

Один скрипт, который превращает чистый сервер на Ubuntu/Debian в защищённый хост
для [Hermes Agent](https://github.com/NousResearch/hermes-agent). Агент работает от
отдельного непривилегированного пользователя в песочнице systemd, а не от root.

[English version](README.md)

## Зачем

Hermes сам выполняет shell-команды, ходит в браузере и ставит скиллы. Стандартная
установка кладёт его в `/root/.hermes`, и любая команда, которую решит выполнить
модель (или подсунет prompt injection), выполняется **от root**. Скрипт ставит Hermes
тем же официальным способом, но под отдельной учёткой без возможности повысить права.

## Быстрый старт

На свежем сервере, от root:

```bash
curl -fsSL https://raw.githubusercontent.com/AntonyN0P/hermes-secure-deploy/main/install.sh -o install.sh
less install.sh            # прочитай: это один файл
sudo bash install.sh
```

Скрипт задаёт несколько вопросов и делает следующее:

1. **Swap**: если RAM + swap меньше 3.5 ГБ (VPS на 1–2 ГБ), предлагает создать
   swap-файл (`/swapfile-hermes`, до 4 ГБ, `vm.swappiness=10`), чтобы установку и
   агента не убил OOM. В контейнерах и при нехватке диска шаг пропускается.
1. **Укрепление ОС** (по желанию): автоустановка обновлений безопасности, fail2ban
   для SSH, ufw (входящие закрыты, кроме SSH), вход по SSH только по ключу.
   Последний пункт предлагается, только если уже есть `authorized_keys`, чтобы
   не отрезать себе доступ.
2. **Учётка `hermes`**: системный пользователь, пароль заблокирован, без sudo, не
   состоит в группах `docker`/`adm`/`lxd`/…, домашний каталог `0700`.
3. **Установка Hermes**: скачивает официальный установщик, показывает его sha256 и
   запускает **от `hermes`**, не от root. Заодно ставит системные библиотеки для
   встроенного Chromium.
4. **Telegram**: проверяет токен бота через API и требует **allow-list** ID
   пользователей, чтобы чужие не управляли агентом. Токен вводится скрыто и не
   попадает в командную строку.
5. **Модель**: запускает официальный мастер `hermes setup model` от `hermes`.
6. **systemd**: юнит gateway пишется из статического шаблона, песочница
   добавляется отдельным drop-in-файлом. Root никогда не запускает
   `gateway install` самого Hermes: root не должен выполнять код, который агент
   может изменить. Веб-дашборд ставится по желанию и слушает только `127.0.0.1`.
7. **Проверка**: gateway работает от `hermes`, `NoNewPrivileges` активен, Telegram
   подключён. Учётка не может использовать sudo, читать `/etc/shadow`, заходить в
   `/root` и работать с Docker.

Запускать повторно безопасно: готовые шаги пропускаются, остальные
перенастраиваются.

## Что ограничивает песочница

`/etc/systemd/system/hermes-gateway.service.d/10-hardening.conf`:

| Настройка | Эффект |
|---|---|
| `User=hermes` | не root, нет sudo |
| `NoNewPrivileges`, пустой `CapabilityBoundingSet`, `RestrictSUIDSGID` | setuid-бинарники (sudo, su…) не дают повысить права |
| `ProtectSystem=strict` | вся ФС только для чтения… |
| `ProtectHome=tmpfs` + `BindPaths=/home/hermes` | …чужие домашние каталоги и `/root` не видны, писать можно только в `/home/hermes` |
| `ProtectProc=invisible` | процессы других пользователей (и их аргументы) скрыты |
| `PrivateTmp` | свой `/tmp` |
| `ProtectKernel*`, `ProtectControlGroups`, `ProtectClock`, `ProtectHostname` | нельзя трогать ядро и системные настройки |

## Без вопросов (автоматизация)

```bash
TELEGRAM_BOT_TOKEN=123456:ABC... TELEGRAM_ALLOWED_USERS=111111111 \
sudo -E bash install.sh --non-interactive \
  --env OPENROUTER_API_KEY=sk-or-... \
  --hardening --firewall --no-dashboard
```

После этого выбери модель: `hermes setup model`. Все опции: `bash install.sh --help`.

## Эксплуатация

| Задача | Команда |
|---|---|
| CLI Hermes (из-под root) | `hermes <команда>` (обёртка сама запускает от `hermes`) |
| Статус / логи | `systemctl status hermes-gateway`, `journalctl -u hermes-gateway -f` |
| Сменить модель | `hermes setup model && systemctl restart hermes-gateway` |
| Поправить секреты | `sudo -u hermes nano /home/hermes/.hermes/.env` |
| Обновить Hermes | `sudo bash install.sh --update` |
| Дашборд | `ssh -L 9119:127.0.0.1:9119 root@СЕРВЕР`, затем открыть http://127.0.0.1:9119 |
| Удалить | `sudo bash uninstall.sh` (данные остаются) / `--purge` (бэкап, затем удаление) |

## От чего это *не* защищает

Задача скрипта — не отдавать модели root. Полной изоляции он не даёт:

- Агент может прочитать **свои** секреты (`.env`: ключ API модели, токен бота), и
  prompt injection может их утащить. Используй ключи с лимитом трат и
  перевыпускай их при подозрениях.
- Исходящая сеть открыта. Чтобы её ограничить, посмотри на egress-файрвол Hermes
  (`hermes egress`).
- У любого из allow-list в Telegram по сути есть shell от `hermes`.
- Держи агента на **отдельном** VPS, не ставь рядом другие сервисы.

## Требования

Ubuntu 22.04+ или Debian 12+ с systemd, x86_64 или arm64, около 2 ГБ RAM и 6 ГБ
свободного места, исходящий HTTPS.

## Лицензия

MIT. Проект не связан с Nous Research; Hermes Agent — их разработка.
