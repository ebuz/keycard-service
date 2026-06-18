# Keycard Service

Systemd-managed RFID door access control for UBC Sailing Club.
Replaces the legacy cron-based uhppoted setup with a proper git repo,
systemd timers, pinned builds from source, and version-controlled rules.

## Hardware

Three UHPPOTE UT0311-L0x controllers on Jericho Sailing Centre LAN:

| Controller | Address | Door 1 | Door 2 | Door 3 | Door 4 |
|------------|---------|--------|--------|--------|--------|
| 423195692 | 192.168.1.25:60000 | Club Room Main | Hobie Room | Fixit Room Main | Fixit Room Slider |
| 423195744 | 192.168.1.26:60000 | UnusedD21 | UnusedD22 | Exec Locker (*) | UnusedD24 |
| 423195750 | 192.168.1.27:60000 | Kayak Locker (*) | Windsurf L1 Locker (*) | Windsurf L2 Locker (*) | Club Room Slider |

(*) Decommissioned — no physical RFID reader; managed via combination locks.

## Repo Structure

```
config/          Deployment configuration files
rules/           Canonical GRL access rules (default) + local override support
scripts/         Bash scripts for each operational workflow
systemd/         systemd service and timer units
bin/             Compiled Go binaries (built from source at install time)
tests/           Testing harness using uhppote-simulator
docs/            Legacy documentation and migration notes
Makefile         Pins uhppoted source versions, clones, and builds
```

## Dependencies

- Go 1.22+ (for building uhppoted from source)
- systemd
- sqlite3 (for event import)
- curl (for telemetry + alerting)
- Standard POSIX tools

## Installation

1. Clone the repo to /opt/keycard-service (or your preferred path).
2. Build the required Go binaries:

```bash
make build-tools
# For tests, also build the simulator:
make build-simulator
```

3. Install systemd units, scripts, and config:

```bash
sudo make install
```

4. Set up credentials and environment overrides:

```bash
sudo cp config/default.env /etc/default/keycard-service
sudo editor /etc/default/keycard-service
```

5. Create the `keycard` user and data directories:

```bash
sudo useradd -r -s /usr/sbin/nologin keycard
sudo chown -R keycard:keycard /var/lib/keycard-service
```

6. Enable and start the timers:

```bash
sudo systemctl enable --now keycard-event-pull.timer
sudo systemctl enable --now keycard-event-report.timer
sudo systemctl enable --now keycard-acl-sync.timer
sudo systemctl enable --now keycard-acl-sync-force.timer
sudo systemctl enable --now keycard-clock-sync.timer
# Optional telemetry:
# sudo systemctl enable --now keycard-telemetry.timer
```

## systemd Services

| Service | Timer | Schedule | Purpose |
|---------|-------|----------|---------|
| keycard-event-pull | keycard-event-pull.timer | hourly | Pull events from controllers |
| keycard-event-report | keycard-event-report.timer | 02:30 daily | Import events to SQLite, upload sheets |
| keycard-acl-sync | keycard-acl-sync.timer | every 8 minutes | Sync member ACL from Wild Apricot |
| keycard-acl-sync-force | keycard-acl-sync-force.timer | 02:32 daily | Force ACL sync |
| keycard-clock-sync | keycard-clock-sync.timer | 02:30 daily | Set controller clocks |
| keycard-telemetry | keycard-telemetry.timer | hourly (optional) | Gather disk/IP/health telemetry |
| keycard-alert-handler | (on failure) | immediate | Dispatch alerts via Discord or email |

All services have OnFailure= hooks to the alert handler.

## Configuration

### Environment Overrides

Set these in `/etc/default/keycard-service`:

- `WI...D` — Wild Apricot API credentials JSON
- `GOOGLE_CREDENTIALS` — Google Sheets API credentials JSON
- `SPREADSHEET` — Google Sheets URL for reporting
- `RULES_URL` — Optional remote GRL rules URL (overrides repo default)
- `KEYCARD_TELEMETRY` — Set to `1` to enable telemetry gatherer
- `DISCORD_ALERT_WEBHOOK` — Discord webhook for failure alerts
- `ALERT_EMAIL` — Email address for failure alerts

### Access Rules (GRL)

The canonical rules live in `rules/access-rules.grl`. These describe which
Wild Apricot member groups have access to which doors. The rules are edited
via git commits and PRs.

At deployment time, you can set `RULES_URL` in `/etc/default/keycard-service`
to point at a remote URL (e.g. a Google Drive sharing link) instead of using
the repo-bundled rules. If `RULES_URL` is empty or unset, the default rules
from the repo are used.

## Testing

The test harness uses the uhppote-simulator to validate all scripts:

```bash
make test
```

This builds the simulator, starts it, runs each script in a controlled
environment, and reports pass/fail. You can also run individual tests:

```bash
bash tests/run-tests.sh
```

## Alerting

Failed systemd units trigger `keycard-alert-handler` which calls `scripts/alert`.
The alert script attempts, in order:

1. Discord webhook (`DISCORD_ALERT_WEBHOOK`)
2. Discord bot (`DISCORD_BOT_TOKEN` + `DISCORD_ALERT_CHANNEL_ID`)
3. Email (`ALERT_EMAIL`)

For Discord bot integration with the existing BlackbeardBot:
- The keycard user does not run the bot. The bot runs under the `blackbeard` user.
- Option A: Use a dedicated webhook (no bot interaction needed).
- Option B: Share a bot token + channel ID if the keycard user should post directly.

## Logs

All services log to journald:

```bash
sudo journalctl -u keycard-acl-sync
sudo journalctl -u keycard-event-pull --since "1 hour ago"
```

Logs are rotated automatically by journald. No Loggly required.

## Lockfiles

Under systemd, explicit lockfiles are redundant. Each service is a `Type=oneshot`
unit; systemd naturally prevents concurrent runs of the same unit. The legacy
cron lockfile (`uhppoted-app-wild-apricot.lock`) has been removed.

## Migration from Legacy Cron

The old system used these cron jobs (see `docs/original-cron.txt`):

```
0  * * * *   get-events           → keycard-event-pull.timer
30 2 * * *   set-time (3x)        → keycard-clock-sync.timer
30 2 * * *   ubcs-events          → keycard-event-report.timer
*/8 * * * *  wild-apricot         → keycard-acl-sync.timer
32 2 * * *   wild-apricot --force → keycard-acl-sync-force.timer
13 * * * *   loggly               → REMOVED (logs now in journald)
```

Legacy scripts (all inactive) that were NOT ported:
- `google-sheets` / `ubcs-acl` — superseded by Wild Apricot sync
- `fetch-mail` / `notifications` — email-triggered sync, disabled
- `loggly` — hardcoded Loggly token, replaced by journald
- Old binary directories `uhppoted_v0.8.11/` and `development/` — obsolete

## Security Notes

- Credential files live in `/etc/keycard-service/credentials/` (mode 0600).
- `/etc/default/keycard-service` is source-controlled environment overrides.
- No secrets are committed to git. Use the `.env` template as a reference.
- The old Loggly token has been removed.

## License

Same as the uhppoted project (MIT).
