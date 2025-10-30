# OpenShift-specific targets for MCP Server
#
# This file contains targets for setting up and managing MCP server
# on OpenShift clusters with Keycloak OIDC authentication.

##@ OpenShift Keycloak Setup

.PHONY: openshift-deploy-keycloak
openshift-deploy-keycloak:
	@bash hack/openshift-deploy-keycloak.sh

.PHONY: openshift-full-setup
openshift-full-setup: ## Complete OpenShift setup: Enable OIDC, deploy Keycloak, create realm (no env vars needed)
	@echo "========================================="
	@echo "OpenShift MCP Server - Complete Setup"
	@echo "========================================="
	@echo ""
	@echo "This will:"
	@echo "  1. Enable ExternalOIDC feature gate (TechPreview)"
	@echo "  2. Deploy Keycloak while cluster rolls out"
	@echo "  3. Configure OpenShift Authentication with Keycloak"
	@echo "  4. Create the 'openshift' realm for MCP"
	@echo ""
	@echo "Step 1: Enabling ExternalOIDC feature gate..."
	@CURRENT_FEATURE_SET=$$(oc get featuregate cluster -o jsonpath='{.spec.featureSet}' 2>/dev/null || echo ""); \
	if [ "$$CURRENT_FEATURE_SET" != "TechPreviewNoUpgrade" ]; then \
		echo "  Enabling TechPreviewNoUpgrade feature set..."; \
		oc patch featuregate cluster --type=merge -p='{"spec":{"featureSet":"TechPreviewNoUpgrade"}}' || { \
			echo "❌ Failed to enable feature gate"; \
			exit 1; \
		}; \
		echo "  ✅ Feature gate enabled"; \
		echo "  ⚠️  Control plane will restart (this takes 10-15 minutes)"; \
	else \
		echo "  ✅ TechPreviewNoUpgrade already enabled"; \
	fi
	@echo ""
	@echo "Step 2: Deploying Keycloak (while cluster rolls out)..."
	@$(MAKE) -s openshift-deploy-keycloak
	@echo ""
	@echo "Step 3: Configuring OpenShift Authentication..."
	@if [ ! -f /tmp/keycloak-credentials.env ]; then \
		echo "❌ Keycloak credentials file not found"; \
		exit 1; \
	fi; \
	set -a && \
	. /tmp/keycloak-credentials.env && \
	set +a && \
	$(MAKE) -s openshift-configure-authentication KEYCLOAK_URL=$$KEYCLOAK_URL
	@echo ""
	@echo "Step 4: Setting up Keycloak realm..."
	@set -a && \
	. /tmp/keycloak-credentials.env && \
	set +a && \
	bash hack/openshift-keycloak-setup-realm.sh
	@echo ""
	@echo "🎉 OpenShift MCP Server setup complete!"
	@echo ""
	@echo "⚠️  Note: kube-apiserver rollout may still be in progress"
	@echo "  Check status with: make openshift-status"
	@echo "  Wait for completion: oc wait --for=condition=Progressing=False --timeout=20m clusteroperator/kube-apiserver"

.PHONY: openshift-keycloak-setup
openshift-keycloak-setup: ## Setup existing Keycloak for MCP (requires: KEYCLOAK_URL, KEYCLOAK_ADMIN_USER, KEYCLOAK_ADMIN_PASSWORD)
	@echo "========================================="
	@echo "OpenShift MCP Server Setup"
	@echo "========================================="
	@echo ""
	@if [ -z "$$KEYCLOAK_URL" ]; then \
		echo "❌ Error: KEYCLOAK_URL environment variable is required"; \
		echo "   Example: export KEYCLOAK_URL=https://keycloak.example.com"; \
		exit 1; \
	fi; \
	if [ -z "$$KEYCLOAK_ADMIN_USER" ]; then \
		echo "❌ Error: KEYCLOAK_ADMIN_USER environment variable is required"; \
		exit 1; \
	fi; \
	if [ -z "$$KEYCLOAK_ADMIN_PASSWORD" ]; then \
		echo "❌ Error: KEYCLOAK_ADMIN_PASSWORD environment variable is required"; \
		exit 1; \
	fi; \
	echo "Step 1: Configuring OpenShift Authentication..." && \
	$(MAKE) -s openshift-configure-authentication KEYCLOAK_URL="$$KEYCLOAK_URL" && \
	echo "" && \
	echo "Step 2: Setting up Keycloak realm..." && \
	KEYCLOAK_URL="$$KEYCLOAK_URL" \
	KEYCLOAK_ADMIN_USER="$$KEYCLOAK_ADMIN_USER" \
	KEYCLOAK_ADMIN_PASSWORD="$$KEYCLOAK_ADMIN_PASSWORD" \
	KEYCLOAK_CA_CERT="$$KEYCLOAK_CA_CERT" \
	KUBECONFIG="$$KUBECONFIG" \
	bash hack/openshift-keycloak-setup-realm.sh
	@echo ""
	@echo "🎉 OpenShift MCP Server setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Wait for kube-apiserver rollout: oc wait --for=condition=Progressing=False --timeout=20m clusteroperator/kube-apiserver"
	@echo "  2. Check status: make openshift-status"
	@echo "  3. Test with MCP server using _output/ocp-config.toml"

.PHONY: openshift-configure-authentication
openshift-configure-authentication:
	@echo "Configuring OpenShift Authentication CR..."
	@if [ -z "$(KEYCLOAK_URL)" ]; then \
		echo "❌ Error: KEYCLOAK_URL environment variable is required"; \
		echo "   Example: export KEYCLOAK_URL=https://keycloak.example.com"; \
		exit 1; \
	fi; \
	echo ""; \
	echo "Step 1: Enabling ExternalOIDC feature gate..."; \
	CURRENT_FEATURE_SET=$$(oc get featuregate cluster -o jsonpath='{.spec.featureSet}' 2>/dev/null || echo ""); \
	if [ "$$CURRENT_FEATURE_SET" != "TechPreviewNoUpgrade" ]; then \
		echo "  Enabling TechPreviewNoUpgrade feature set (required for ExternalOIDC)..."; \
		oc patch featuregate cluster --type=merge -p='{"spec":{"featureSet":"TechPreviewNoUpgrade"}}' || { \
			echo "⚠️  Could not enable feature gate - ExternalOIDC may not be available"; \
		}; \
		echo "  ⚠️  Control plane will restart (this takes 10-15 minutes)"; \
		echo "  ⚠️  Waiting 2 minutes for initial rollout..."; \
		sleep 120; \
	else \
		echo "  ✅ TechPreviewNoUpgrade already enabled"; \
	fi; \
	echo ""; \
	echo "Step 2: Waiting for kube-apiserver to be ready..."; \
	for i in $$(seq 1 30); do \
		if oc wait --for=condition=Available --timeout=10s clusteroperator/kube-apiserver 2>/dev/null; then \
			echo "  ✅ kube-apiserver is ready"; \
			break; \
		fi; \
		echo "  Waiting for kube-apiserver (attempt $$i/30)..."; \
		sleep 10; \
	done; \
	echo ""; \
	echo "Step 3: Configuring OIDC provider CA certificate..."; \
	kubectl get configmap -n openshift-config-managed default-ingress-cert -o jsonpath='{.data.ca-bundle\.crt}' > /tmp/keycloak-ca.crt && \
	echo "  Extracted OpenShift ingress CA ($$(wc -l < /tmp/keycloak-ca.crt) lines)"; \
	oc delete configmap keycloak-oidc-ca -n openshift-config 2>/dev/null || true; \
	oc create configmap keycloak-oidc-ca -n openshift-config --from-file=ca-bundle.crt=/tmp/keycloak-ca.crt; \
	echo "  ✅ CA certificate configmap created"; \
	echo ""; \
	echo "Step 4: Configuring OIDC provider..."; \
	ISSUER_URL="$(KEYCLOAK_URL)/realms/openshift"; \
	echo "  Issuer URL: $$ISSUER_URL"; \
	echo "  Audiences: openshift, mcp-server"; \
	CURRENT_ISSUER=$$(oc get authentication.config.openshift.io/cluster -o jsonpath='{.spec.oidcProviders[0].issuer.issuerURL}' 2>/dev/null || echo ""); \
	if [ "$$CURRENT_ISSUER" = "$$ISSUER_URL" ]; then \
		echo "  ✅ OIDC provider already configured with correct issuer"; \
	else \
		if [ -n "$$CURRENT_ISSUER" ]; then \
			echo "  Updating existing OIDC provider from $$CURRENT_ISSUER to $$ISSUER_URL..."; \
			printf '[{"op":"replace","path":"/spec/oidcProviders/0/issuer/issuerURL","value":"%s"},{"op":"replace","path":"/spec/oidcProviders/0/issuer/audiences","value":["openshift","mcp-server"]}]' "$$ISSUER_URL" > /tmp/oidc-patch.json; \
		else \
			echo "  Creating new OIDC provider configuration..."; \
			printf '[{"op":"remove","path":"/spec/webhookTokenAuthenticator"},{"op":"replace","path":"/spec/type","value":"OIDC"},{"op":"add","path":"/spec/oidcProviders","value":[{"name":"keycloak","issuer":{"issuerURL":"%s","audiences":["openshift","mcp-server"],"issuerCertificateAuthority":{"name":"keycloak-oidc-ca"}},"claimMappings":{"username":{"claim":"preferred_username","prefixPolicy":"NoPrefix"}}}]}]' "$$ISSUER_URL" > /tmp/oidc-patch.json; \
		fi; \
		oc patch authentication.config.openshift.io/cluster --type=json -p="$$(cat /tmp/oidc-patch.json)" 2>&1 || { \
			echo "⚠️  Could not configure OIDC - check if ExternalOIDC feature gate is enabled"; \
			echo "  Current feature set: $$(oc get featuregate cluster -o jsonpath='{.spec.featureSet}')"; \
			exit 1; \
		}; \
	fi; \
	echo "✅ Authentication CR configured with OIDC provider"

.PHONY: openshift-status
openshift-status: ## Show OpenShift OIDC authentication status
	@echo "========================================="
	@echo "OpenShift OIDC Authentication Status"
	@echo "========================================="
	@echo ""
	@if oc get authentication.config.openshift.io/cluster >/dev/null 2>&1; then \
		echo "Issuer URL:"; \
		oc get authentication.config.openshift.io/cluster -o jsonpath='{.spec.oidcProviders[0].issuer.issuerURL}'; \
		echo ""; \
		echo ""; \
		echo "Audiences:"; \
		oc get authentication.config.openshift.io/cluster -o jsonpath='{.spec.oidcProviders[0].issuer.audiences}' | jq .; \
		echo ""; \
		echo "Username Claim Mapping:"; \
		oc get authentication.config.openshift.io/cluster -o jsonpath='{.spec.oidcProviders[0].claimMappings.username}' | jq .; \
		echo ""; \
	else \
		echo "❌ No OIDC authentication configured"; \
	fi; \
	echo ""; \
	echo "RBAC Bindings for MCP user:"; \
	oc get clusterrolebinding | grep mcp || echo "  No MCP-related bindings found"; \
	echo "========================================="

.PHONY: openshift-realm-setup
openshift-realm-setup:
	@bash hack/openshift-keycloak-setup-realm.sh
