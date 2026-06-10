# =====================
# ⚙️ Project Variables
# =====================
IMG ?= docker.io/vasudevdchavan/k8soperator
VERSION ?= 0.1.3

BUNDLE_IMG ?= $(IMG)-bundle:$(VERSION)
INDEX_IMG ?= $(IMG)-index:$(VERSION)
OPERATOR_NAME ?= k8soperator
CATALOG_DIR ?= catalog
CATALOGSOURCE_YAML ?= catalogsource.yaml
CONTAINER_TOOL ?= docker


## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

LOCALBIN ?= $(shell pwd)/bin
KUSTOMIZE ?= $(LOCALBIN)/kustomize
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
GOLANGCI_LINT ?= $(LOCALBIN)/golangci-lint

KUSTOMIZE_VERSION ?= v5.7.1
CONTROLLER_TOOLS_VERSION ?= v0.19.0
GOLANGCI_LINT_VERSION ?= v2.4.0

SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

# ======================
# 🔧 Helper Targets
# ======================

.PHONY: help
help: ## Show help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

# =========================
##@ 🛠️  Development Targets
# =========================



.PHONY: manifests
manifests: controller-gen ## Generate CRDs and RBAC
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate deepcopy code
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: fmt
fmt: ## Run go fmt
	go fmt ./...

.PHONY: vet
vet: ## Run go vet
	go vet ./...

.PHONY: lint
lint: golangci-lint ## Lint the code
	$(GOLANGCI_LINT) run

# =========================
##@ 🏗️  Build & Deploy
# =========================

.PHONY: build
build: manifests generate fmt vet ## Build the manager
	go build -o bin/manager cmd/main.go

.PHONY: docker-build
docker-build: ## Build docker image
	$(CONTAINER_TOOL) build -t $(IMG):$(VERSION) .

.PHONY: docker-push
docker-push: ## Push docker image
	$(CONTAINER_TOOL) push $(IMG):$(VERSION)


.PHONY: deploy
deploy: kustomize ## Deploy to cluster
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}:$(VERSION)
	$(KUSTOMIZE) build config/default | kubectl apply -f -

.PHONY: undeploy
undeploy: kustomize ## Remove from cluster
	$(KUSTOMIZE) build config/default | kubectl delete -f -

.PHONY: install
install: manifests kustomize ## Install CRDs
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: kustomize ## Uninstall CRDs
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

# =========================
##@ 📦 OLM Bundle Targets
# =========================

.PHONY: bundle
bundle: manifests kustomize ## Generate bundle
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG):$(VERSION)
	operator-sdk generate kustomize manifests -q
	$(KUSTOMIZE) build config/manifests | operator-sdk generate bundle -q --overwrite --version $(VERSION)

.PHONY: bundle-build
bundle-build: bundle ## Build bundle image
	$(CONTAINER_TOOL) build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

.PHONY: bundle-push
bundle-push: ## Push bundle image
	$(CONTAINER_TOOL) push $(BUNDLE_IMG)


# =========================
##@ 📚 Catalog Targets
# =========================

.PHONY: catalog-init
catalog-init: clean
	@echo "📦 Initializing catalog metadata for operator '$(OPERATOR_NAME)'..."
	mkdir -p $(CATALOG_DIR)
	opm init $(OPERATOR_NAME) --default-channel=stable -o yaml > $(CATALOG_DIR)/index.yaml

.PHONY: catalog-render
catalog-render: catalog-init
	@echo "🖌 Rendering bundle manifests..."
	opm render $(BUNDLE_IMG) --output=yaml >> $(CATALOG_DIR)/index.yaml
	@echo "---" >> $(CATALOG_DIR)/index.yaml
	@echo "schema: olm.channel" >> $(CATALOG_DIR)/index.yaml
	@echo "package: $(OPERATOR_NAME)" >> $(CATALOG_DIR)/index.yaml
	@echo "name: stable" >> $(CATALOG_DIR)/index.yaml
	@echo "entries:" >> $(CATALOG_DIR)/index.yaml
	@echo "- name: $(OPERATOR_NAME).v$(VERSION)" >> $(CATALOG_DIR)/index.yaml
	opm generate dockerfile $(CATALOG_DIR)

.PHONY: catalog-build
catalog-build: catalog-render
	@echo "📚 Building catalog index image $(INDEX_IMG)..."
	$(CONTAINER_TOOL) build -t $(INDEX_IMG) -f $(CATALOG_DIR).Dockerfile .

.PHONY: catalog-push
catalog-push:
	@echo "📤 Pushing catalog index image $(INDEX_IMG)..."
	$(CONTAINER_TOOL) push $(INDEX_IMG)



.PHONY: generate-catalogsource
generate-catalogsource:
	@echo "apiVersion: operators.coreos.com/v1alpha1" > $(CATALOGSOURCE_YAML)
	@echo "kind: CatalogSource" >> $(CATALOGSOURCE_YAML)
	@echo "metadata:" >> $(CATALOGSOURCE_YAML)
	@echo "  name: $(OPERATOR_NAME)-catalog" >> $(CATALOGSOURCE_YAML)
	@echo "  namespace: olm" >> $(CATALOGSOURCE_YAML)
	@echo "spec:" >> $(CATALOGSOURCE_YAML)
	@echo "  sourceType: grpc" >> $(CATALOGSOURCE_YAML)
	@echo "  image: $(INDEX_IMG)" >> $(CATALOGSOURCE_YAML)
	@echo "  displayName: $(OPERATOR_NAME) Catalog" >> $(CATALOGSOURCE_YAML)
	@echo "  publisher: $(OPERATOR_NAME) Dev Team" >> $(CATALOGSOURCE_YAML)

# =========================
##@ 🚀 Full Release
# =========================

.PHONY: olm-release
olm-release: build docker-build docker-push bundle-build bundle-push catalog-render catalog-build catalog-push generate-catalogsource
	@echo "✅ OLM release steps completed successfully."

# =========================
##@ 🧹 Cleanup
# =========================

.PHONY: clean
clean:
	rm -rf bundle catalog *.yaml bin catalog.Dockerfile

# =========================
##@ 🔧 Tooling
# =========================

.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary.
$(KUSTOMIZE): $(LOCALBIN)
	$(call go-install-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v5,$(KUSTOMIZE_VERSION))

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary.
$(CONTROLLER_GEN): $(LOCALBIN)
	$(call go-install-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen,$(CONTROLLER_TOOLS_VERSION))

.PHONY: golangci-lint
golangci-lint: $(GOLANGCI_LINT) ## Download golangci-lint locally if necessary.
$(GOLANGCI_LINT): $(LOCALBIN)
	$(call go-install-tool,$(GOLANGCI_LINT),github.com/golangci/golangci-lint/v2/cmd/golangci-lint,$(GOLANGCI_LINT_VERSION))



# go-install-tool will 'go install' any package with custom target and name of binary, if it doesn't exist
# $1 - target path with name of binary
# $2 - package url which can be installed
# $3 - specific version of package
define go-install-tool
@[ -f "$(1)-$(3)" ] && [ "$$(readlink -- "$(1)" 2>/dev/null)" = "$(1)-$(3)" ] || { \
set -e; \
package=$(2)@$(3) ;\
echo "Downloading $${package}" ;\
rm -f $(1) ;\
GOBIN=$(LOCALBIN) go install $${package} ;\
mv $(1) $(1)-$(3) ;\
} ;\
ln -sf $$(realpath $(1)-$(3)) $(1)
endef

.PHONY: check-tools
check-tools:
	@command -v operator-sdk >/dev/null 2>&1 || (echo "Error: operator-sdk not installed" && exit 1)
	@command -v opm >/dev/null 2>&1 || (echo "Error: opm not installed" && exit 1)
	@echo "✅ Required tools are installed."