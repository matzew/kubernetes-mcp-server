#!/usr/bin/env bash

# Script to add hub Keycloak's CA certificate to managed cluster's Keycloak truststore
# This enables JWKS signature validation for cross-realm token exchange

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Required environment variables
: "${HUB_KEYCLOAK_ISSUER:?Error: HUB_KEYCLOAK_ISSUER is required (e.g., https://keycloak.example.com/realms/openshift)}"
: "${KUBECONFIG:?Error: KUBECONFIG is required for managed cluster access}"

echo "========================================="
echo "Adding Hub CA to Keycloak Truststore"
echo "========================================="
echo "Hub Issuer: $HUB_KEYCLOAK_ISSUER"
echo ""

# Extract hub's hostname from issuer URL
HUB_HOST=$(echo "$HUB_KEYCLOAK_ISSUER" | sed 's|https://||' | sed 's|http://||' | cut -d'/' -f1)
echo "Hub hostname: $HUB_HOST"

# Extract hub CA certificate
echo "Extracting hub CA certificate..."
CA_TEMP_FILE=$(mktemp)
if ! echo | openssl s_client -showcerts -connect "$HUB_HOST:443" 2>/dev/null | \
     openssl x509 -outform PEM > "$CA_TEMP_FILE"; then
  echo -e "${RED}❌ Failed to extract CA certificate${NC}"
  echo "Please ensure $HUB_HOST is accessible and uses HTTPS"
  rm -f "$CA_TEMP_FILE"
  exit 1
fi

echo -e "${GREEN}✅ CA certificate extracted${NC}"
echo ""

# Verify it's a valid certificate
if ! openssl x509 -in "$CA_TEMP_FILE" -noout -subject 2>/dev/null; then
  echo -e "${RED}❌ Invalid certificate extracted${NC}"
  rm -f "$CA_TEMP_FILE"
  exit 1
fi

echo "Certificate subject:"
openssl x509 -in "$CA_TEMP_FILE" -noout -subject
echo ""

# Create ConfigMap with CA certificate
echo "Creating ConfigMap in keycloak namespace..."
if kubectl create configmap hub-ca-cert -n keycloak \
     --from-file=hub-ca.crt="$CA_TEMP_FILE" \
     --dry-run=client -o yaml | kubectl apply -f -; then
  echo -e "${GREEN}✅ ConfigMap created/updated${NC}"
else
  echo -e "${RED}❌ Failed to create ConfigMap${NC}"
  rm -f "$CA_TEMP_FILE"
  exit 1
fi

rm -f "$CA_TEMP_FILE"
echo ""

# Check if Keycloak deployment exists
if ! kubectl get deployment keycloak -n keycloak &>/dev/null; then
  echo -e "${RED}❌ Keycloak deployment not found in namespace 'keycloak'${NC}"
  exit 1
fi

# Check if volumes already exist in the deployment
VOLUMES_EXIST=$(kubectl get deployment keycloak -n keycloak -o json | jq '.spec.template.spec.volumes != null')

echo "Patching Keycloak deployment..."

if [ "$VOLUMES_EXIST" = "true" ]; then
  # Check if hub-ca-cert volume already exists
  VOLUME_EXISTS=$(kubectl get deployment keycloak -n keycloak -o json | \
    jq '.spec.template.spec.volumes[] | select(.name == "hub-ca-cert") | .name' | wc -l)

  if [ "$VOLUME_EXISTS" -gt 0 ]; then
    echo -e "${YELLOW}⚠️  hub-ca-cert volume already exists, updating ConfigMap reference${NC}"
    # Just restart the deployment to pick up the new ConfigMap
    kubectl rollout restart deployment/keycloak -n keycloak
  else
    # Volumes exist, add to array
    kubectl patch deployment keycloak -n keycloak --type=json -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/volumes/-",
        "value": {
          "name": "hub-ca-cert",
          "configMap": {"name": "hub-ca-cert"}
        }
      },
      {
        "op": "add",
        "path": "/spec/template/spec/containers/0/volumeMounts/-",
        "value": {
          "name": "hub-ca-cert",
          "mountPath": "/opt/keycloak/conf/truststores/hub-ca.crt",
          "subPath": "hub-ca.crt",
          "readOnly": true
        }
      }
    ]'
  fi
else
  # No volumes array, create it
  kubectl patch deployment keycloak -n keycloak --type=json -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/volumes",
      "value": [{
        "name": "hub-ca-cert",
        "configMap": {"name": "hub-ca-cert"}
      }]
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/volumeMounts",
      "value": [{
        "name": "hub-ca-cert",
        "mountPath": "/opt/keycloak/conf/truststores/hub-ca.crt",
        "subPath": "hub-ca.crt",
        "readOnly": true
      }]
    }
  ]'
fi

echo -e "${GREEN}✅ Deployment patched${NC}"
echo ""

# Wait for rollout
echo "Waiting for Keycloak rollout to complete..."
if kubectl rollout status deployment/keycloak -n keycloak --timeout=180s; then
  echo -e "${GREEN}✅ Keycloak restarted successfully${NC}"
else
  echo -e "${RED}❌ Rollout failed or timed out${NC}"
  exit 1
fi

echo ""
echo "========================================="
echo -e "${GREEN}✅ Hub CA certificate added to Keycloak${NC}"
echo "========================================="
echo ""
echo "The certificate is now available in Keycloak's truststore at:"
echo "  /opt/keycloak/conf/truststores/hub-ca.crt"
echo ""
echo "Keycloak will use this certificate to validate the hub's"
echo "TLS connection when fetching JWKS for token signature validation."
