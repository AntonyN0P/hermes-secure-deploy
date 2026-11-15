# hermes-secure-deploy

One script that turns a fresh Ubuntu/Debian server into a locked-down host for
[Hermes Agent](https://github.com/NousResearch/hermes-agent): the agent runs as a
dedicated unprivileged user inside a systemd sandbox, not as root.

[Русская версия](README.ru.md)

## Why

Hermes runs shell commands, browses the web and installs skills on its own. The
quick-start installs it into `/root/.hermes`, so every command the model decides to
run, and every prompt-injected command, runs **as root**. This script installs
Hermes the same official way, but under a separate account that cannot escalate.

## Quick start

On a fresh server, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/AntonyN0P/hermes-secure-deploy/main/install.sh -o install.sh
less install.sh            # read it, it's one file
sudo bash install.sh
```

The script asks a few questions and walks you through:

1. **OS hardening** (optional): unattended security updates, fail2ban for SSH, ufw
   (deny all incoming except SSH), and key-only SSH (offered only if an
   `authorized_keys` already exists, so you can't lock yourself out).
2. **Service account `hermes`**: system user, locked password, no sudo, not in
   `docker`/`adm`/`lxd`/… groups, home `0700`.
3. **Hermes install**: downloads the official installer, prints its sha256 and
   runs it **as `hermes`**, never as root. It also installs the Chromium libraries
   the browser tool needs.
4. **Telegram**: validates the bot token against the Telegram API and requires a
   user-ID **allow-list**, so strangers can't drive your agent. The token is read
   hidden and never passed on a command line.
5. **Model provider**: runs the official `hermes setup model` wizard as `hermes`.
6. **systemd**: writes the gateway unit from a static template plus a sandbox
   drop-in. Root never runs Hermes' own `gateway install`, because root must not
   execute code the agent can modify. The web dashboard is optional and bound to
   `127.0.0.1` only.
7. **Verification**: checks the gateway runs as `hermes`, has `NoNewPrivileges`,
   connected to Telegram, and that the account can't sudo, read `/etc/shadow`,
   enter `/root` or use Docker.

Re-running the script is safe: finished steps are skipped and it re-configures
the rest.

## What the sandbox enforces

`/etc/systemd/system/hermes-gateway.service.d/10-hardening.conf`:

| Setting | Effect |
|---|---|
| `User=hermes` | no root, no sudo |
| `NoNewPrivileges`, empty `CapabilityBoundingSet`, `RestrictSUIDSGID` | setuid binaries (sudo, su, …) can't elevate |
| `ProtectSystem=strict` | the whole filesystem is read-only… |
| `ProtectHome=tmpfs` + `BindPaths=/home/hermes` | …other homes and `/root` are invisible; only `/home/hermes` is writable |
| `ProtectProc=invisible` | other users' processes (and their command lines) are hidden |
| `PrivateTmp` | private `/tmp` |
| `ProtectKernel*`, `ProtectControlGroups`, `ProtectClock`, `ProtectHostname` | no kernel or system tampering |

## Non-interactive use

```bash
TELEGRAM_BOT_TOKEN=123456:ABC... TELEGRAM_ALLOWED_USERS=111111111 \
sudo -E bash install.sh --non-interactive \
  --env OPENROUTER_API_KEY=sk-or-... \
  --hardening --firewall --no-dashboard
```

Then pick a model with `hermes setup model`. Run `bash install.sh --help` for all
options.

## Day-2 operations

| Task | Command |
|---|---|
| Hermes CLI (as root) | `hermes <cmd>` (a wrapper runs it as `hermes`) |
| Status / logs | `systemctl status hermes-gateway`, `journalctl -u hermes-gateway -f` |
| Change model | `hermes setup model && systemctl restart hermes-gateway` |
| Edit secrets | `sudo -u hermes nano /home/hermes/.hermes/.env` |
| Update Hermes | `sudo bash install.sh --update` |
| Dashboard | `ssh -L 9119:127.0.0.1:9119 root@SERVER`, then open http://127.0.0.1:9119 |
| Remove | `sudo bash uninstall.sh` (keeps data) / `--purge` (backs up, then deletes) |

## What this does *not* protect against

This is about not handing the model root. It is not a full containment:

- The agent can read **its own** secrets (`.env`: model API key, bot token). A
  prompt injection could leak them. Use keys with spending limits and rotate them
  if in doubt.
- Outbound network is open. Look at Hermes' egress firewall (`hermes egress`) if
  you need to restrict it.
- Anyone on the Telegram allow-list effectively has a shell as `hermes`.
- Run the agent on a **dedicated** VPS: don't put other services on the same box.

## Requirements

Ubuntu 22.04+ or Debian 12+ with systemd, x86_64 or arm64, about 2 GB RAM and
6 GB free disk, outbound HTTPS.

## License

MIT. Not affiliated with Nous Research; Hermes Agent is their project.
