#!/usr/bin/env bash

# Script to configure Keycloak cross-realm token exchange trust
# This allows a managed cluster's Keycloak to accept tokens from the hub's Keycloak

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Required environment variables
: "${MANAGED_KEYCLOAK_URL:?Error: MANAGED_KEYCLOAK_URL is required}"
: "${MANAGED_KEYCLOAK_ADMIN_USER:?Error: MANAGED_KEYCLOAK_ADMIN_USER is required}"
: "${MANAGED_KEYCLOAK_ADMIN_PASSWORD:?Error: MANAGED_KEYCLOAK_ADMIN_PASSWORD is required}"
: "${HUB_KEYCLOAK_ISSUER:?Error: HUB_KEYCLOAK_ISSUER is required}"
: "${MANAGED_REALM:=openshift}"
: "${MANAGED_CLIENT_ID:=mcp-server}"

echo "========================================="
echo "Configuring Cross-Realm Token Exchange"
echo "========================================="
echo "Managed Cluster Keycloak: $MANAGED_KEYCLOAK_URL"
echo "Hub Issuer: $HUB_KEYCLOAK_ISSUER"
echo "Realm: $MANAGED_REALM"
echo "Client: $MANAGED_CLIENT_ID"
echo ""

# Get admin access token for managed cluster's Keycloak
echo "Step 1: Getting admin access token..."
RESPONSE=$(curl -sk -X POST "$MANAGED_KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=$MANAGED_KEYCLOAK_ADMIN_USER" \
  -d "password=$MANAGED_KEYCLOAK_ADMIN_PASSWORD" \
  -d "grant_type=password" \
  -d "client_id=admin-cli")

TOKEN=$(echo "$RESPONSE" | jq -r '.access_token // empty' 2>/dev/null)
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo -e "${RED}❌ Failed to get access token${NC}"
  echo "Response: $RESPONSE"
  exit 1
fi
echo -e "${GREEN}✅ Got admin access token${NC}"

# Step 2: Get the mcp-server client configuration
echo ""
echo "Step 2: Fetching $MANAGED_CLIENT_ID client configuration..."
CLIENT_RESPONSE=$(curl -sk -X GET \
  "$MANAGED_KEYCLOAK_URL/admin/realms/$MANAGED_REALM/clients?clientId=$MANAGED_CLIENT_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json")

CLIENT_UUID=$(echo "$CLIENT_RESPONSE" | jq -r '.[0].id // empty' 2>/dev/null)
if [ -z "$CLIENT_UUID" ] || [ "$CLIENT_UUID" = "null" ]; then
  echo -e "${RED}❌ Client $MANAGED_CLIENT_ID not found${NC}"
  echo "Response: $CLIENT_RESPONSE"
  exit 1
fi
echo -e "${GREEN}✅ Found client: $CLIENT_UUID${NC}"

# Step 3: Get current client configuration
echo ""
echo "Step 3: Getting current client configuration..."
CURRENT_CONFIG=$(curl -sk -X GET \
  "$MANAGED_KEYCLOAK_URL/admin/realms/$MANAGED_REALM/clients/$CLIENT_UUID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json")

echo -e "${GREEN}✅ Retrieved current configuration${NC}"

# Step 4: Create identity provider for hub
echo ""
echo "Step 4: Configuring identity provider for hub issuer..."

# Extract hub realm from issuer URL
HUB_REALM=$(echo "$HUB_KEYCLOAK_ISSUER" | sed -n 's|.*/realms/\(.*\)|\1|p')
if [ -z "$HUB_REALM" ]; then
  echo -e "${YELLOW}⚠️  Could not extract realm from issuer URL, using 'openshift'${NC}"
  HUB_REALM="openshift"
fi

# Check if identity provider already exists
IDP_ALIAS="hub-$HUB_REALM"
IDP_EXISTS=$(curl -sk -X GET \
  "$MANAGED_KEYCLOAK_URL/admin/realms/$MANAGED_REALM/identity-provider/instances/$IDP_ALIAS" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -w "%{http_code}" -o /dev/null)

if [ "$IDP_EXISTS" = "200" ]; then
  echo -e "${YELLOW}⚠️  Identity provider $IDP_ALIAS already exists, updating...${NC}"
  # Update existing IDP
  curl -sk -X PUT \
    "$MANAGED_KEYCLOAK_URL/admin/realms/$MANAGED_REALM/identity-provider/instances/$IDP_ALIAS" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @- <<EOF
{
  "alias": "$IDP_ALIAS",
  "displayName": "Hub Keycloak ($HUB_REALM)",
  "providerId": "oidc",
  "enabled": true,
  "trustEmail": true,
  "storeToken": false,
  "addReadTokenRoleOnCreate": false,
  "authenticateByDefault": false,
  "linkOnly": false,
  "firstBrokerLoginFlowAlias": "first broker login",
  "config": {
    "issuer": "$HUB_KEYCLOAK_ISSUER",
    "validateSignature": "false",
    "useJwksUrl": "false",
    "tokenUrl": "$HUB_KEYCLOAK_ISSUER/protocol/openid-connect/token",
    "authorizationUrl": "$HUB_KEYCLOAK_ISSUER/protocol/openid-connect/auth",
    "userInfoUrl": "$HUB_KEYCLOAK_ISSUER/protocol/openid-connect/userinfo",
    "clientAuthMethod": "client_secret_post",
    "syncMode": "IMPORT"
  }
}
EOF
else
  echo -e "${GREEN}Creating new identity provider $IDP_ALIAS...${NC}"
  # Create new IDP
  curl -sk -X POST \
    "$MANAGED_KEYCLOAK_URL/admin/realms/$MANAGED_REALM/identity-provider/instances" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @- <<EOF
{
  "alias": "$IDP_ALIAS",
  "displayName": "Hub Keycloak ($HUB_REALM)",
  "providerId": "oidc",
  "enabled": true,
  "trustEmail": true,
  "storeToken": false,
  "addReadTokenRoleOnCreate": false,
  "authenticateByDefault": false,
  "linkOnly": false,
  "firstBrokerLoginFlowAlias": "first broker login",
  "config": {
    "issuer": "$HUB_KEYCLOAK_ISSUER",
    "validateSignature": "false",
    "useJwksUrl": "false",
    "tokenUrl": "$HUB_KEYCLOAK_ISSUER/protocol/openid-connect/token",
    "authorizationUrl": "$HUB_KEYCLOAK_ISSUER/protocol/openid-connect/auth",
    "userInfoUrl": "$HUB_KEYCLOAK_ISSUER/protocol/openid-connect/userinfo",
    "clientAuthMethod": "client_secret_post",
    "syncMode": "IMPORT"
  }
}
EOF
fi

echo -e "${GREEN}✅ Identity provider configured${NC}"

# Step 5: Update client to enable token exchange with the hub IDP
echo ""
echo "Step 5: Enabling token exchange for $MANAGED_CLIENT_ID..."

# Update the client attributes to allow token exchange from hub IDP
UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | jq \
  --arg idp "$IDP_ALIAS" \
  '.attributes["token.exchange.subject.issuer"] = $idp |
   .attributes["token.exchange.subject.audience"] = "openshift"')

curl -sk -X PUT \
  "$MANAGED_KEYCLOAK_URL/admin/realms/$MANAGED_REALM/clients/$CLIENT_UUID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$UPDATED_CONFIG"

echo -e "${GREEN}✅ Token exchange enabled${NC}"

# Step 6: Grant token-exchange permission to the client
echo ""
echo "Step 6: Granting token-exchange permissions..."

# Get the token-exchange permission
PERMISSION_RESPONSE=$(curl -sk -X GET \
  "$MANAGED_KEYCLOAK_URL/admin/realms/$MANAGED_REALM/clients/$CLIENT_UUID/management/permissions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json")

PERMISSIONS_ENABLED=$(echo "$PERMISSION_RESPONSE" | jq -r '.enabled // false')

if [ "$PERMISSIONS_ENABLED" != "true" ]; then
  echo "Enabling client permissions management..."
  curl -sk -X PUT \
    "$MANAGED_KEYCLOAK_URL/admin/realms/$MANAGED_REALM/clients/$CLIENT_UUID/management/permissions" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"enabled": true}'
fi

echo -e "${GREEN}✅ Permissions configured${NC}"

echo ""
echo "========================================="
echo -e "${GREEN}✅ Cross-realm token exchange setup complete!${NC}"
echo "========================================="
echo ""
echo "Configuration Summary:"
echo "  Managed Cluster: $MANAGED_KEYCLOAK_URL"
echo "  Realm: $MANAGED_REALM"
echo "  Client: $MANAGED_CLIENT_ID"
echo "  Trusted Hub Issuer: $HUB_KEYCLOAK_ISSUER"
echo "  Identity Provider: $IDP_ALIAS"
echo ""
echo "The managed cluster's Keycloak is now configured to accept"
echo "tokens from the hub's Keycloak via token exchange."
echo ""
