.DEFAULT_GOAL := help
SHELL := /bin/bash
M = $(shell printf "\033[34;1m>>\033[0m")
rwildcard = $(foreach d,$(wildcard $(1:=/*)),$(call rwildcard,$d,$2) $(filter $(subst *,%,$2),$d))

TARGET_NAME = $(firstword $(MAKECMDGOALS))
RUN_ARGS = $(filter-out $@, $(MAKEOVERRIDES) $(MAKECMDGOALS))
OS := $(shell uname -s)
TOOLS_DIR ?= .tools
SUDO_PASSWORD ?= human

VECTOR_VERSION ?= 0.35.0
# если установлен в системе, то доступен как команда в /usr/bin/vector
VECTOR_BINARY ?= $(TOOLS_DIR)/vector_$(VECTOR_VERSION)_$(OS)_amd64
VECTOR_CONFIG_DIR ?= $(PWD)/.generated/vector_config
YQ_VERSION ?= 4.30.5
JV_VERSION ?= 0.4.0


ifeq ($(OS), Darwin)
	VECTOR_TAR_URL := https://packages.timber.io/vector/$(VECTOR_VERSION)/vector-$(VECTOR_VERSION)-x86_64-apple-darwin.tar.gz
	VECTOR_TAR_BIN_PATH := ./vector-x86_64-apple-darwin/bin/vector
else
	VECTOR_TAR_URL := https://packages.timber.io/vector/$(VECTOR_VERSION)/vector-$(VECTOR_VERSION)-x86_64-unknown-linux-gnu.tar.gz
	VECTOR_TAR_BIN_PATH := ./vector-x86_64-unknown-linux-gnu/bin/vector
endif

YQ_BINARY := $(TOOLS_DIR)/yq_$(YQ_VERSION)_$(OS)_amd64
JV_BINARY := $(TOOLS_DIR)/jv_$(JV_VERSION)_$(OS)_amd64

YQ_BINARY_URL := https://github.com/mikefarah/yq/releases/download/v$(YQ_VERSION)/yq_$(OS)_amd64


.PHONY: install-dependencies
install-dependencies: ## Install required dependencies
	mkdir -p $(TOOLS_DIR)
ifeq (,$(wildcard $(YQ_BINARY)))
	wget -qO $(YQ_BINARY) $(YQ_BINARY_URL) --show-progress && chmod +x $(YQ_BINARY)
endif
ifeq (,$(wildcard $(JV_BINARY)))
	$(info $(M) Building jv from source...)
	GO111MODULE="on" GOBIN=$(shell realpath $(TOOLS_DIR)) go install github.com/santhosh-tekuri/jsonschema/cmd/jv@v$(JV_VERSION)
	mv $(TOOLS_DIR)/jv $(JV_BINARY)
endif


.PHONY: install-dev-dependencies
install-dev-dependencies:  ## Install required dev tools
	$(info $(M) Install required dev tools...)
ifneq ($(CI), true)
# Local environment as GitLab CI/CD environment var not definded or != true
	@echo "Check if python installed"
	@command -v pip >/dev/null 2>&1 && echo "OK" || { \
			echo "$(M) Installing python3 pip..."; \
			echo "$(M) You may be prompted for sudo password..."; \
			if [ "$(OS)" = "Darwin" ]; then \
				brew install python3 && (curl https://bootstrap.pypa.io/get-pip.py | python3) \
			else \
				sudo apt-get update && (sudo apt-get install python3 && curl https://bootstrap.pypa.io/get-pip.py | python3) \
			fi; \
		}
endif
	python3 -m pip install -r ./dev-requirements.txt



.PHONY: download-vector-bin
download-vector-bin: ## Download vector.dev binary
ifeq (,$(wildcard $(VECTOR_BINARY)))
	$(info $(M) Download vector.dev $(VECTOR_BINARY) binary...)
	@wget -qO- https://packages.timber.io/vector/$(VECTOR_VERSION)/vector-$(VECTOR_VERSION)-x86_64-unknown-linux-gnu.tar.gz  --show-progress \
		| tar xvzf - -C $(TOOLS_DIR) "$(VECTOR_TAR_BIN_PATH)"  --strip-components=3 \
	&& chmod +x $(TOOLS_DIR)/vector && mv $(TOOLS_DIR)/vector $(VECTOR_BINARY)
endif


.PHONY: validate-metrics-catalog-spec
validate-metrics-catalog-spec: ## Validates metrics-catalog.yml
	$(info $(M) Validate vars/metric-catalog.yml with json-schema...)
	$(JV_BINARY) ./schema/vectordev-metrics-catalog.json ./ansible-playbook/vars/metrics-catalog.yml


.PHONY: lint-vector-config
lint-vector-config: ## Check vector files for invalid or deprecated functions
	$(info $(M) Check for deprecated functions vector.dev...)
	@FOUND_FILES=$$(grep -r -l "to_timestamp" files/); \
	if [ -n "$$FOUND_FILES" ]; then \
		echo "ERROR: Some files contain deprecated to_timestamp func, replace with parse_timestamp (see https://vector.dev/highlights/2023-08-15-0-32-0-upgrade-guide/#deprecations)"; \
		echo "$$FOUND_FILES"; \
		exit 1; \
	else \
		echo "OK"; \
		exit 0; \
	fi

.PHONY: generate-vector-conf
generate-vector-conf: | validate-metrics-catalog-spec lint-vector-config ## Generate vector.dev at localhost
	@mkdir -p $(VECTOR_CONFIG_DIR)
	$(info $(M) Ansible generates vector.dev config for localhost...)
	$(eval $@_tmpfile := $(shell mktemp ansible-playbook/playbook.tmpXXX))
	@$(YQ_BINARY) ea '.[0].hosts = "127.0.0.1", .[0].connection = "local"' ./ansible-playbook/playbook.yml > $($@_tmpfile)
	@$(YQ_BINARY) -i ea 'del(.[0].roles)' $($@_tmpfile)

	@echo Build and copy config files...
	VECTOR_KAFKA_PASSWORD=fake \
	VECTOR_KAFKA_USERNAME=fake \
	ansible-playbook -connection=local --inventory localhost, $($@_tmpfile) \
		--tags aggregator \
		--extra-vars "development_mode=true" \
		--extra-vars "ansible_sudo_pass=$(SUDO_PASSWORD)" \
		--extra-vars "local_build=true" \
		--extra-vars "vector_config_dir=$(VECTOR_CONFIG_DIR)" \
		--extra-vars "vector_kafka_bootstrap_servers=FAKE_KAFKA_SERVER" \
		--extra-vars "vector_kafka_topics=FAKE_KAFKA_TOPIC" \
		--skip-tags install,setup
	@rm -rf $($@_tmpfile)
# popd

.PHONY: validate-vector-conf
validate-vector-conf: generate-vector-conf ## Validate current vector.dev config
	$(info $(M) Validate vector config at $(VECTOR_CONFIG_DIR)...)
	$(VECTOR_BINARY) validate -C $(VECTOR_CONFIG_DIR) --no-environment

.PHONY: test-vector-transfroms
test-vector-transfroms: | generate-vector-conf validate-vector-conf  ## Run vector.dev transform tests
	$(info $(M) Run transforms tests with config $(VECTOR_CONFIG_DIR)...)
	$(VECTOR_BINARY) test $(VECTOR_CONFIG_DIR)/*_sources_*.toml $(VECTOR_CONFIG_DIR)/*transforms_*.toml $(VECTOR_CONFIG_DIR)/*_tests_*.toml

.PHONY: test-vector-transfrom
test-vector-transfrom:  ## Run vector.dev test for a specifed test file
ifndef file
	@echo "To run use file=testfile make ..."
else
	$(info $(M) Run a transform test with config $(VECTOR_CONFIG_DIR)...)
	@echo Test file: $(file)
	$(VECTOR_BINARY) test $(VECTOR_CONFIG_DIR)/*_sources_*.toml $(VECTOR_CONFIG_DIR)/*transforms_*.toml $(file)
endif

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

%:
	@:
