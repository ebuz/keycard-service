#!/bin/bash
# Integration tests for keycard-service and blackbeard-bot deployment/upgrade flow.
# Run with sudo: sudo bash tests/run-install-tests.sh

set -euo pipefail

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

KEYCARD_DIR="/home/ebuz/rpi/keycard-service"
BLACKBEARD_DIR="/home/ebuz/rpi/blackbeard/BlackbeardBot"

pass()   { TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  PASS: $1"; }
fail()   { TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  FAIL: $1"; }
skip()   { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); echo "  SKIP: $1"; }
assert() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected $2, got $1)"; fi; }
assert_file() { if [ -f "$1" ]; then pass "$2"; else fail "$2 (file $1 not found)"; fi; }
assert_dir()  { if [ -d "$1" ]; then pass "$2"; else fail "$2 (dir $1 not found)"; fi; }
assert_no()   { if [ ! -f "$1" ] && [ ! -d "$1" ]; then pass "$2"; else fail "$2 (exists: $1)"; fi; }

echo "======================================"
echo "  Deployment Integration Tests"
echo "======================================"
echo ""

# =============================================================================
# PHASE 1: Pre-conditions
# =============================================================================
echo "--- Phase 1: Pre-conditions ---"

assert_file "${KEYCARD_DIR}/Makefile"       "keycard-service Makefile exists"
assert_file "${BLACKBEARD_DIR}/Makefile"    "blackbeard-bot Makefile exists"
assert_file "${KEYCARD_DIR}/scripts/get-events" "keycard get-events script exists"
assert_file "${KEYCARD_DIR}/scripts/acl-sync"   "keycard acl-sync script exists"
assert_dir  "${KEYCARD_DIR}/systemd"        "keycard systemd/ directory exists"
assert_dir  "${BLACKBEARD_DIR}/systemd"     "blackbeard systemd/ directory exists"
assert_dir  "${BLACKBEARD_DIR}/config"      "blackbeard config/ directory exists"

# =============================================================================
# PHASE 2: keycard-service installation
# =============================================================================
echo ""
echo "--- Phase 2: keycard-service install ---"

# 2a: Build tools
echo "  [2a] make build-tools..."
(cd "${KEYCARD_DIR}" && make build-tools 2>&1) | tail -1
assert_file "${KEYCARD_DIR}/bin/uhppote-cli"          "uhppote-cli binary built"
assert_file "${KEYCARD_DIR}/bin/uhppoted-app-sheets"  "uhppoted-app-sheets binary built"
assert_file "${KEYCARD_DIR}/bin/uhppoted-app-wild-apricot" "uhppoted-app-wild-apricot binary built"

# 2b: Install (run with sudo because it touches /etc /opt /var)
echo "  [2b] make install..."
sudo make -C "${KEYCARD_DIR}" install 2>&1 | tail -3

# 2c: Verify installation
echo "  [2c] Verify file placement..."
assert_file "/opt/keycard-service/bin/uhppote-cli"          "binary in /opt/keycard-service/bin/"
assert_file "/opt/keycard-service/bin/uhppoted-app-sheets"  "sheets binary installed"
assert_file "/opt/keycard-service/bin/uhppoted-app-wild-apricot" "wild-apricot binary installed"
assert_dir  "/opt/keycard-service/scripts"                  "scripts directory"
assert_dir  "/opt/keycard-service/rules"                     "rules directory"
assert_file "/opt/keycard-service/rules/access-rules.grl"   "GRL rules installed"
assert_dir  "/etc/keycard-service/credentials"               "credentials dir"
assert_file "/etc/keycard-service/uhppoted.conf"             "config installed"
assert_dir  "/var/lib/keycard-service/events"                "events dir"
assert_dir  "/var/lib/keycard-service/db"                    "db dir"
assert_dir  "/var/lib/keycard-service/logs"                  "logs dir"
assert_dir  "/var/lib/keycard-service/telemetry"             "telemetry dir"
assert_dir  "/var/lib/keycard-service/wild-apricot/logs"     "wild-apricot workdir"
assert_dir  "/var/lib/keycard-service/wild-apricot/reports"  "wild-apricot reports dir"

# 2d: Verify systemd units
echo "  [2d] Verify systemd units..."
for unit in keycard-event-pull keycard-event-report keycard-acl-sync keycard-acl-sync-force keycard-clock-sync keycard-telemetry keycard-alert-handler; do
    assert_file "/etc/systemd/system/${unit}.service" "systemd unit ${unit}.service installed"
done
for timer in keycard-event-pull keycard-event-report keycard-acl-sync keycard-acl-sync-force keycard-clock-sync keycard-telemetry; do
    assert_file "/etc/systemd/system/${timer}.timer" "systemd timer ${timer}.timer installed"
done

# 2e: Validate systemd unit files parse correctly
echo "  [2e] Validate systemd syntax..."
if command -v systemd-analyze >/dev/null 2>&1; then
    for unit in /etc/systemd/system/keycard-*.service; do
        if systemd-analyze verify "${unit}" 2>/dev/null; then
            pass "systemd-analyze verify $(basename ${unit})"
        else
            fail "systemd-analyze verify $(basename ${unit})"
        fi
    done
else
    skip "systemd-analyze not available"
fi

# 2f: Check /etc/default/keycard-service was created
assert_file "/etc/default/keycard-service" "env defaults file created"

# =============================================================================
# PHASE 3: blackbeard-bot installation
# =============================================================================
echo ""
echo "--- Phase 3: blackbeard-bot install ---"

echo "  [3a] make install (creates venv, installs deps)..."
sudo make -C "${BLACKBEARD_DIR}" install 2>&1 | tail -3

# 3b: Verify venv and deps
echo "  [3b] Verify venv..."
assert_dir  "${BLACKBEARD_DIR}/.venv" "venv created"
assert_file "${BLACKBEARD_DIR}/.venv/bin/python" "venv python3 exists"
echo "  ...checking key packages..."
"${BLACKBEARD_DIR}/.venv/bin/pip" list --format=columns 2>/dev/null | grep -i discord || fail "discord.py not installed in venv"
"${BLACKBEARD_DIR}/.venv/bin/pip" list --format=columns 2>/dev/null | grep -i gspread || fail "gspread not installed in venv"
"${BLACKBEARD_DIR}/.venv/bin/pip" list --format=columns 2>/dev/null | grep -i google-api-python-client || fail "google-api-python-client not installed"

# 3c: Verify systemd units
echo "  [3c] Verify systemd units..."
for unit in blackbeard-bot blackbeard-backup; do
    assert_file "/etc/systemd/system/${unit}.service" "blackbeard ${unit}.service installed"
done
assert_file "/etc/systemd/system/blackbeard-backup.timer" "blackbeard-backup.timer installed"

# 3d: Validate systemd unit file contents (paths expected at /opt/blackbeard-bot/ on deploy)
echo "  [3d] Verify unit file contents..."
for unit in "blackbeard-bot.service" "blackbeard-backup.service"; do
    if grep -q 'WorkingDirectory=/opt/blackbeard-bot' "/etc/systemd/system/${unit}" && \
       grep -q 'EnvironmentFile=-/etc/default/blackbeard-bot' "/etc/systemd/system/${unit}" && \
       grep -q 'StandardOutput=journal' "/etc/systemd/system/${unit}"; then
        pass "unit file ${unit} has correct structure"
    else
        fail "unit file ${unit} is malformed"
    fi
done

# 3e: Check env file
assert_file "/etc/default/blackbeard-bot" "blackbeard env defaults created"

# =============================================================================
# PHASE 4: keycard-service upgrade simulation
# =============================================================================
echo ""
echo "--- Phase 4: keycard-service upgrade (build-install) ---"

# 4a: Make a small change to simulate an update
echo "  [4a] Simulating code update..."
echo "# Simulated upgrade test $(date)" | sudo tee -a "${KEYCARD_DIR}/scripts/get-events" >/dev/null

# 4b: Run build-install
echo "  [4b] Running sudo make build-install..."
sudo make -C "${KEYCARD_DIR}" build-install 2>&1 | tail -3
assert_file "/opt/keycard-service/bin/uhppote-cli" "binaries still present after update"
assert_file "/etc/keycard-service/uhppoted.conf"   "config preserved after update"

# 4c: Verify existing data survived
assert_dir "/var/lib/keycard-service/db" "data directory preserved"

# 4d: Clean up simulated change
cd "${KEYCARD_DIR}" && git checkout -- scripts/get-events

# =============================================================================
# PHASE 5: blackbeard-bot upgrade simulation
# =============================================================================
echo ""
echo "--- Phase 5: blackbeard-bot upgrade (build-install) ---"

echo "  [5a] Running sudo make build-install..."
sudo make -C "${BLACKBEARD_DIR}" build-install 2>&1 | tail -3
assert_file "${BLACKBEARD_DIR}/.venv/bin/python" "venv preserved after update"
assert_dir  "${BLACKBEARD_DIR}/.venv" "venv preserved"

# =============================================================================
# PHASE 6: keycard-service test harness
# =============================================================================
echo ""
echo "--- Phase 6: keycard-service functional test (simulator) ---"

# Build the simulator if not already done
if [ ! -f "${KEYCARD_DIR}/bin/uhppote-simulator" ]; then
    echo "  [6a] Building simulator..."
    make -C "${KEYCARD_DIR}" build-simulator 2>&1 | tail -1
fi
assert_file "${KEYCARD_DIR}/bin/uhppote-simulator" "uhppote-simulator binary"

echo "  [6b] Running test harness..."
bash "${KEYCARD_DIR}/tests/run-tests.sh" && pass "keycard functional tests passed" || fail "keycard functional tests failed"

# =============================================================================
# PHASE 7: Uninstall (non-destructive)
# =============================================================================
echo ""
echo "--- Phase 7: Uninstall (non-destructive) ---"

# 7a: keycard uninstall
echo "  [7a] keycard-service uninstall..."
sudo make -C "${KEYCARD_DIR}" uninstall 2>&1 | tail -3
assert_no  "/opt/keycard-service/bin"       "bin dir removed by uninstall"
assert_no  "/opt/keycard-service/scripts"    "scripts dir removed"
assert_no  "/etc/systemd/system/keycard-event-pull.service" "systemd unit removed"
# These MUST survive:
assert_file "/etc/keycard-service/uhppoted.conf"     "config preserved after uninstall"
assert_dir  "/etc/keycard-service/credentials"        "credentials preserved after uninstall"
assert_dir  "/var/lib/keycard-service"                "data preserved after uninstall"
assert_file "/etc/default/keycard-service"            "env file preserved after uninstall"

# 7b: blackbeard uninstall
echo "  [7b] blackbeard-bot uninstall..."
sudo make -C "${BLACKBEARD_DIR}" uninstall 2>&1 | tail -3
assert_no  "${BLACKBEARD_DIR}/.venv"                  "venv removed"
assert_no  "/etc/systemd/system/blackbeard-bot.service" "systemd unit removed"
# These MUST survive:
assert_dir  "/etc/blackbeard-bot/credentials"         "credentials preserved"
assert_file "/etc/default/blackbeard-bot"              "env file preserved"

# =============================================================================
# PHASE 8: Re-install (simulate first-time setup after uninstall)
# =============================================================================
echo ""
echo "--- Phase 8: Re-install after uninstall ---"

sudo make -C "${KEYCARD_DIR}" install 2>&1 | tail -3
assert_file "/opt/keycard-service/bin/uhppote-cli"     "re-installed binaries OK"
assert_file "/etc/systemd/system/keycard-event-pull.service" "re-installed systemd unit OK"
assert_file "/etc/keycard-service/uhppoted.conf"       "config still exists"

# =============================================================================
# PHASE 9: Cleanup (purge)
# =============================================================================
echo ""
echo "--- Phase 9: Purge (full removal) ---"

sudo make -C "${KEYCARD_DIR}" purge 2>&1 | tail -3
assert_no  "/etc/keycard-service"           "config fully removed by purge"
assert_no  "/var/lib/keycard-service"       "data fully removed by purge"
assert_no  "/etc/default/keycard-service"   "env file removed by purge"

sudo make -C "${BLACKBEARD_DIR}" purge 2>&1 | tail -3
assert_no  "/etc/blackbeard-bot"            "config fully removed by purge"
assert_no  "/etc/default/blackbeard-bot"    "env file removed by purge"

# =============================================================================
# RESULTS
# =============================================================================
echo ""
echo "======================================"
echo "  Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped"
echo "======================================"

if [ $TESTS_FAILED -gt 0 ]; then
    echo "Some tests FAILED. Review output above."
    exit 1
fi

echo "All tests passed."
exit 0