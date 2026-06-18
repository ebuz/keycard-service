# keycard-service build system
# Pins uhppoted source versions and compiles required binaries.
#
# The repo should be cloned directly to /opt/keycard-service so that
# git pull updates everything in place.
#
# Update flow:
#   cd /opt/keycard-service && sudo make build-install
#
# This rebuilds Go binaries, re-installs systemd units + config,
# reloads systemd, and restarts any active timers.

# Pinned versions
UHPPOTED_VERSION ?= v0.8.11

# Required tools and their source repositories
TOOLS := \
	uhppote-cli:github.com/uhppoted/uhppote-cli \
	uhppoted-app-sheets:github.com/uhppoted/uhppoted-app-sheets \
	uhppoted-app-wild-apricot:github.com/uhppoted/uhppoted-app-wild-apricot \
	uhppote-simulator:github.com/uhppoted/uhppote-simulator

BUILD_DIR := build
BIN_DIR := bin
GO := go

# Paths the service expects
DEST_PREFIX := /opt/keycard-service
SCRIPTS_DIR := $(DEST_PREFIX)/scripts
RULES_DIR   := $(DEST_PREFIX)/rules
BIN_DEST    := $(DEST_PREFIX)/bin
CONFIG_DIR  := /etc/keycard-service
CRED_DIR    := $(CONFIG_DIR)/credentials
DATA_DIR    := /var/lib/keycard-service
ENV_FILE    := /etc/default/keycard-service
SYSTEMD_DIR := /etc/systemd/system

TIMERS = keycard-event-pull.timer keycard-event-report.timer \
         keycard-acl-sync.timer keycard-acl-sync-force.timer \
         keycard-clock-sync.timer keycard-telemetry.timer

ALL_TIMERS = $(TIMERS)

.PHONY: all clean build-tools build-simulator test \
        install build-install \
        uninstall purge \
        restart-timers

all: build-tools

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

# === BUILD ===

build-tools: $(BUILD_DIR) $(BIN_DIR)
	@echo "Building uhppoted tools at $(UHPPOTED_VERSION)..."
	@$(foreach tool,$(TOOLS),\
		$(eval NAME := $(word 1,$(subst :, ,$(tool))))\
		$(eval REPO := $(word 2,$(subst :, ,$(tool))))\
		@echo "  building $(NAME)..."; \
		if [ ! -d "$(BUILD_DIR)/$(NAME)" ]; then \
			git clone --depth 1 --branch $(UHPPOTED_VERSION) "https://$(REPO).git" "$(BUILD_DIR)/$(NAME)"; \
		fi; \
		cd "$(BUILD_DIR)/$(NAME)" && $(GO) build -o "../../$(BIN_DIR)/$(NAME)" .; \
	)
	@echo "Done. Binaries in $(BIN_DIR)/"

build-simulator: $(BUILD_DIR) $(BIN_DIR)
	@echo "Building uhppote-simulator at $(UHPPOTED_VERSION)..."
	@if [ ! -d "$(BUILD_DIR)/uhppote-simulator" ]; then \
		git clone --depth 1 --branch $(UHPPOTED_VERSION) "https://github.com/uhppoted/uhppote-simulator.git" "$(BUILD_DIR)/uhppote-simulator"; \
	fi
	@cd "$(BUILD_DIR)/uhppote-simulator" && $(GO) build -o "../../$(BIN_DIR)/uhppote-simulator" .
	@echo "Done. Simulator in $(BIN_DIR)/uhppote-simulator"

test: build-tools build-simulator
	@echo "Running test suite..."
	@./tests/run-tests.sh

# === INSTALL (idempotent — safe to run repeatedly) ===

# build-install is the ONE-LINE update command.
# After git pull, run this. It rebuilds, installs, and activates.
build-install: build-tools install

install:
	@echo "=== Installing keycard-service ==="

	mkdir -p $(BIN_DEST)
	install -m 755 $(BIN_DIR)/uhppote-cli $(BIN_DEST)/
	install -m 755 $(BIN_DIR)/uhppoted-app-sheets $(BIN_DEST)/
	install -m 755 $(BIN_DIR)/uhppoted-app-wild-apricot $(BIN_DEST)/

	mkdir -p $(SCRIPTS_DIR)
	install -m 755 scripts/* $(SCRIPTS_DIR)/

	mkdir -p $(RULES_DIR)
	install -m 644 rules/access-rules.grl $(RULES_DIR)/

	mkdir -p $(CONFIG_DIR)
	mkdir -p $(CRED_DIR)

	@# Preserve existing uhppoted.conf (hardware mapping shouldn't change on update).
	@# Copy the repo version alongside as a reference.
	if [ -f $(CONFIG_DIR)/uhppoted.conf ]; then \
		install -m 600 config/uhppoted.conf $(CONFIG_DIR)/uhppoted.conf.default; \
		echo "  Preserved existing $(CONFIG_DIR)/uhppoted.conf (new template at .default)"; \
	else \
		install -m 600 config/uhppoted.conf $(CONFIG_DIR)/uhppoted.conf; \
	fi

	@# Preserve existing env overrides.
	if [ ! -f $(ENV_FILE) ]; then \
		install -m 644 config/default.env $(ENV_FILE); \
	else \
		install -m 644 config/default.env $(ENV_FILE).default; \
	fi

	@# Create data directories (preserving existing data).
	mkdir -p $(DATA_DIR)
	mkdir -p $(DATA_DIR)/events
	mkdir -p $(DATA_DIR)/db
	mkdir -p $(DATA_DIR)/logs
	mkdir -p $(DATA_DIR)/telemetry
	@# Wild Apricot working dirs
	mkdir -p $(DATA_DIR)/wild-apricot/logs
	mkdir -p $(DATA_DIR)/wild-apricot/reports

	@echo "Installing systemd units..."
	install -m 644 systemd/*.service systemd/*.timer $(SYSTEMD_DIR)/
	systemctl daemon-reload

	@# Restart any timers that are already enabled
	$(foreach timer,$(ALL_TIMERS),\
		if systemctl is-enabled -q $(timer) 2>/dev/null; then \
			echo "  Restarting $(timer)..."; \
			systemctl restart $(timer) 2>/dev/null || true; \
		fi; \
	)

	@echo ""
	@echo "=== Installation complete ==="
	@echo ""
	@echo "Review and set up:"
	@echo "  1. Credentials in $(CRED_DIR)/"
	@echo "     - wild-apricot.json  (Wild Apricot API)"
	@echo "     - google.json        (Google Sheets API)"
	@echo "  2. Review $(CONFIG_DIR)/uhppoted.conf (hardware mapping)"
	@echo "  3. Edit $(ENV_FILE) for env overrides"
	@echo "  4. Ensure 'keycard' user exists:"
	@echo "     sudo useradd -r -s /usr/sbin/nologin keycard"
	@echo "  5. Data ownership:"
	@echo "     sudo chown -R keycard:keycard $(DATA_DIR)"
	@echo ""
	@echo "Enable timers:"
	@echo "     sudo systemctl enable --now $(foreach t,$(TIMERS),$(t) )"

# === UNINSTALL (non-destructive — preserves credentials, data, env) ===

uninstall:
	@echo "Stopping timers..."
	-$(foreach timer,$(ALL_TIMERS),systemctl stop $(timer) 2>/dev/null;)
	@echo "Removing systemd units..."
	-rm -f $(SYSTEMD_DIR)/keycard-*.service $(SYSTEMD_DIR)/keycard-*.timer
	systemctl daemon-reload
	@echo "Removing installed code..."
	-rm -rf $(BIN_DEST)
	-rm -rf $(SCRIPTS_DIR)
	-rm -rf $(RULES_DIR)
	@echo "Preserved:"
	@echo "  $(CONFIG_DIR)/uhppoted.conf"
	@echo "  $(CRED_DIR)/  (credentials untouched)"
	@echo "  $(ENV_FILE)"
	@echo "  $(DATA_DIR)/  (data files untouched)"
	@echo "Uninstall complete."

# === PURGE (full removal including credentials and data) ===

purge: uninstall
	@echo "Removing configuration and data..."
	-rm -rf $(CONFIG_DIR)
	-rm -f $(ENV_FILE)
	-rm -rf $(DATA_DIR)
	@echo "Purge complete."

# === UTILITY ===

restart-timers:
	$(foreach timer,$(ALL_TIMERS),\
		if systemctl is-enabled -q $(timer) 2>/dev/null; then \
			systemctl restart $(timer); \
		fi; \
	)
	@echo "Timers restarted."

clean:
	@echo "Cleaning build artifacts..."
	-rm -rf $(BUILD_DIR) $(BIN_DIR)
