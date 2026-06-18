# keycard-service build system
# Pins uhppoted source versions and compiles required binaries.

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

.PHONY: all clean install build-tools build-simulator test

all: build-tools

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

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

install: build-tools
	@echo "Installing binaries to /opt/keycard-service/bin/"
	@install -d /opt/keycard-service/bin
	@install -m 755 $(BIN_DIR)/uhppote-cli /opt/keycard-service/bin/
	@install -m 755 $(BIN_DIR)/uhppoted-app-sheets /opt/keycard-service/bin/
	@install -m 755 $(BIN_DIR)/uhppoted-app-wild-apricot /opt/keycard-service/bin/
	@install -d /opt/keycard-service/scripts
	@install -m 755 scripts/* /opt/keycard-service/scripts/
	@install -d /opt/keycard-service/rules
	@install -m 644 rules/access-rules.grl /opt/keycard-service/rules/
	@install -d /etc/keycard-service/credentials
	@install -m 600 config/uhppoted.conf /etc/keycard-service/uhppoted.conf
	@install -d /var/lib/keycard-service
	@install -d /var/lib/keycard-service/events
	@install -d /var/lib/keycard-service/db
	@install -d /var/lib/keycard-service/logs
	@install -d /var/lib/keycard-service/telemetry
	@if [ ! -f /etc/default/keycard-service ]; then \
		install -m 644 config/default.env /etc/default/keycard-service; \
	fi
	@echo "Installing systemd units..."
	@install -m 644 systemd/*.service systemd/*.timer /etc/systemd/system/
	@systemctl daemon-reload

	@echo "Installation complete."
	@echo "Next steps:"
	@echo "  1. Copy credentials to /etc/keycard-service/credentials/"
	@echo "  2. Review /etc/keycard-service/uhppoted.conf"
	@echo "  3. Edit /etc/default/keycard-service for environment overrides"
	@echo "  4. Create user: useradd -r -s /usr/sbin/nologin keycard"
	@echo "  5. Set ownership: chown -R keycard:keycard /var/lib/keycard-service"
	@echo "  6. systemctl enable --now keycard-event-pull.timer keycard-event-report.timer keycard-acl-sync.timer keycard-acl-sync-force.timer keycard-clock-sync.timer"

uninstall:
	@echo "Removing installed files..."
	@rm -rf /opt/keycard-service
	@rm -rf /etc/keycard-service
	@rm -f /etc/default/keycard-service
	@rm -f /etc/systemd/system/keycard-*.service /etc/systemd/system/keycard-*.timer
	@systemctl daemon-reload

clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(BUILD_DIR) $(BIN_DIR)
