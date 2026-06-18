# Keycard Service

Systemd-managed RFID door access control for UBC Sailing Club.
Replaces the legacy cron-based uhppoted setup with a proper git repo,
systemd timers, pinned builds from source, and version-controlled rules.

---

## Quick Deploy (New Installation)

```bash
git clone <repo-url> /opt/keycard-service
cd /opt/keycard-service
sudo make build-install
sudo useradd -r -s /usr/sbin/nologin keycard
sudo chown -R keycard:keycard /var/lib/keycard-service

# Copy credentials (mode 0600) to /etc/keycard-service/credentials/
# wild-apricot.json  — Wild Apricot API
# google.json          — Google Sheets API

sudo editor /etc/default/keycard-service
sudo systemctl enable --now keycard-event-pull.timer \
                          keycard-event-report.timer \
                          keycard-acl-sync.timer \
                          keycard-acl-sync-force.timer \
                          keycard-clock-sync.timer
```

## Quick Update (After git pull)

```bash
cd /opt/keycard-service
sudo git pull
sudo make build-install
```

That's it. `make build-install` does everything:
1. Rebuilds Go binaries from pinned source
2. Installs updated scripts, rules, systemd units
3. Preserves your existing config, credentials, data
4. Runs `systemctl daemon-reload`
5. Restarts any already-enabled timers

To see what changed before applying: `git log --oneline` or `git diff`.

---

## How it Works

### Hardware

Three UHPPOTE UT0311-L0x controllers on Jericho Sailing Centre LAN:

| Controller | Address | Door 1 | Door 2 | Door 3 | Door 4 |
|------------|---------|--------|--------|--------|--------|
| 423195692 | 192.168.1.25:60000 | Club Room Main | Hobie Room | Fixit Room Main | Fixit Room Slider |
| 423195744 | 192.168.1.26:60000 | UnusedD21 | UnusedD22 | Exec Locker (*) | UnusedD24 |
| 423195750 | 192.168.1.27:60000 | Kayak Locker (*) | Windsurf L1 Locker (*) | Windsurf L2 Locker (*) | Club Room Slider |

(*) Decommissioned — no physical RFID reader; managed via combination locks.

### Repo Structure

```
config/          Deployment configuration templates (copied to /etc/keycard-service/)
rules/           Canonical GRL access rules
scripts/         Bash scripts for each operational workflow
systemd/         systemd service and timer units
bin/             Compiled Go binaries (built from source, .gitignore)
tests/           Testing harness using uhppote-simulator
docs/            Legacy documentation and migration notes
Makefile         Pins uhppoted source versions, builds, installs
```

### systemd Services

| Service | Timer | Schedule | Purpose |
|---------|-------|----------|---------|
| keycard-event-pull | keycard-event-pull.timer | hourly | Pull events from controllers |
| keycard-event-report | keycard-event-report.timer | 02:30 daily | Import events to SQLite, upload to Google Sheets |
| keycard-acl-sync | keycard-acl-sync.timer | every 8 min | Sync member ACL from Wild Apricot |
| keycard-acl-sync-force | keycard-acl-sync-force.timer | 02:32 daily | Force ACL sync |
| keycard-clock-sync | keycard-clock-sync.timer | 02:30 daily | Set controller clocks |
| keycard-telemetry | keycard-telemetry.timer | hourly (optional) | Gather disk/IP/health telemetry |
| keycard-alert-handler | (on failure) | immediate | Dispatch alerts via Discord or email |

All services have `OnFailure=` hooks pointing at the alert handler, which uses
journald to retrieve the last 20 log lines from the failed unit.

### Configuration

Set these in `/etc/default/keycard-service`:

| Variable | Purpose |
|----------|---------|
| `WILDA_CREDENTIALS` | Wild Apricot API credentials JSON path |
| `GOOGLE_CREDENTIALS` | Google Sheets API credentials JSON path |
| `SPREADSHEET` | Google Sheets URL for reporting |
| `RULES_URL` | Optional remote GRL rules URL (overrides repo default) |
| `KEYCARD_TELEMETRY` | Set to `1` to enable telemetry gatherer |
| `DISCORD_ALERT_WEBHOOK` | Discord webhook for failure alerts |
| `DISCORD_BOT_TOKEN` | Discord bot token (for bot-based alerting) |
| `DISCORD_ALERT_CHANNEL_ID` | Channel ID for bot-based alerts |
| `ALERT_EMAIL` | Email address for failure alerts |

### Access Rules (GRL)

The canonical rules live in `rules/access-rules.grl`. These describe which
Wild Apricot member groups have access to which doors. Rules are edited
via git commits and code review.

At deployment time, you can set `RULES_URL` in `/etc/default/keycard-service`
to point at a remote URL (e.g. a Google Drive sharing link) instead of using
the repo-bundled rules. If unset, the repo rules are used.

### Logs

All services log to journald:

```bash
journalctl -u keycard-acl-sync
journalctl -u keycard-event-pull --since "1 hour ago"
journalctl -u keycard-clock-sync --since yesterday
```

Logs rotate automatically with journald. No Loggly required.

### Lockfiles

Under systemd, explicit lockfiles are redundant. Each service is `Type=oneshot`;
systemd naturally prevents concurrent runs of the same unit. The legacy
`uhppoted-app-wild-apricot.lock` has been removed.

---

## Testing

```bash
make test
```

Builds the simulator, starts it, runs each script against the simulated
controller, and reports pass/fail.

---

## Alerting

Failed units trigger `keycard-alert-handler@<unit>.service`, which calls
`scripts/alert`. The alert script attempts, in order:

1. Discord webhook (`DISCORD_ALERT_WEBHOOK`)
2. Discord bot (`DISCORD_BOT_TOKEN` + `DISCORD_ALERT_CHANNEL_ID`)
3. Email (`ALERT_EMAIL`)

For Discord bot integration with the existing BlackbeardBot:
- BlackbeardBot runs under the `blackbeard` user
- Webhook is the simplest path (no bot token sharing needed)
- Bot token integration is available if preferred

---

## Parallel Deployment

The new service uses isolated paths and can coexist with the legacy cron setup:

| | New service | Legacy cron |
|---|---|---|
| User | `keycard` | `uhppoted` |
| Code | `/opt/keycard-service/` | `/opt/uhppoted/` |
| Data | `/var/lib/keycard-service/` | `/var/ubcs/` |
| Config | `/etc/keycard-service/` | `/etc/uhppoted/` |
| Env | `/etc/default/keycard-service` | (inline in cron) |
| Execution | systemd timers | cron |

**However**, both talk to the same three door controllers via UDP. Running
both ACL sync jobs simultaneously can cause undefined behavior on the
controllers. During parallel testing:

1. Install the new service but **do not enable its timers**.
2. Manually test individual scripts while legacy cron is running safely.
3. When ready to cut over:
   ```bash
   # Disable legacy cron
   sudo -u uhppoted crontab -r
   # Enable new service
   sudo systemctl enable --now keycard-acl-sync.timer \
                             keycard-event-pull.timer \
                             keycard-event-report.timer \
                             keycard-clock-sync.timer
   ```

---

## Migration from Legacy Cron

See `docs/original-cron.txt` for the exact legacy schedule. Summary:

```
Legacy cron job              →    New systemd timer
─────────────────────────────────────────────────────
get-events (hourly)          →    keycard-event-pull.timer
set-time + ubcs-events (02:30) → keycard-clock-sync.timer
                                   keycard-event-report.timer
wild-apricot (every 8 min)   →    keycard-acl-sync.timer
wild-apricot --force (02:32)  →    keycard-acl-sync-force.timer
df + dig (hourly)            →    keycard-telemetry.timer (optional)
loggly (hourly)              →    REMOVED (journald instead)
```

Not ported (all inactive):
- `google-sheets` / `ubcs-acl` — superseded by Wild Apricot sync
- `fetch-mail` / `notifications` — email-triggered pipeline, disabled
- `loggly` — hardcoded token, nobody has Loggly access
- Old binary directories (`uhppoted_v0.8.11/`, `development/`)

---

## Security Notes

- Credential files live in `/etc/keycard-service/credentials/` (mode 0600).
- `/etc/default/keycard-service` is environment overrides (no secrets).
- `make uninstall` preserves credentials, data, and env overrides.
- `make purge` removes everything including credentials and data.
- All service files run as `keycard` user (no root for operational tasks).
- No secrets are committed to git.

---

## License

Same as the uhppoted project (MIT).