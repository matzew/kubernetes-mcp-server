#!/bin/bash
set -euo pipefail

# OpenShift Keycloak Realm Setup Script
# This script sets up the 'openshift' realm for MCP token exchange on any Keycloak instance
#
# Required environment variables:
#   KEYCLOAK_URL           - Keycloak base URL (e.g., https://keycloak.example.com)
#   KEYCLOAK_ADMIN_USER    - Keycloak admin username
#   KEYCLOAK_ADMIN_PASSWORD - Keycloak admin password
#
# Optional environment variables:
#   KEYCLOAK_CA_CERT       - Path to CA certificate for HTTPS verification (optional)
#   KUBECONFIG             - Path to kubeconfig for RBAC setup (defaults to $KUBECONFIG or ~/.kube/config)

# Validate required variables
: "${KEYCLOAK_URL:?Error: KEYCLOAK_URL environment variable is required}"
: "${KEYCLOAK_ADMIN_USER:?Error: KEYCLOAK_ADMIN_USER environment variable is required}"
: "${KEYCLOAK_ADMIN_PASSWORD:?Error: KEYCLOAK_ADMIN_PASSWORD environment variable is required}"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEYCLOAK_CONFIG_DIR="$REPO_ROOT/dev/config/keycloak"

# Set curl options based on CA cert availability
CURL_OPTS="-sk"
if [ -n "${KEYCLOAK_CA_CERT:-}" ]; then
    CURL_OPTS="--cacert $KEYCLOAK_CA_CERT"
fi

echo "========================================="
echo "Setting up OpenShift Realm for Token Exchange"
echo "========================================="
echo "Using Keycloak at $KEYCLOAK_URL"
echo ""
echo "Getting admin access token..."

RESPONSE=$(curl $CURL_OPTS -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$KEYCLOAK_ADMIN_USER" \
    -d "password=$KEYCLOAK_ADMIN_PASSWORD" \
    -d "grant_type=password" \
    -d "client_id=admin-cli")

TOKEN=$(echo "$RESPONSE" | jq -r '.access_token // empty' 2>/dev/null)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "❌ Failed to get access token"
    echo "Response was: $RESPONSE" | head -c 200
    echo ""
    echo "Check if:"
    echo "  - Keycloak is running and accessible at $KEYCLOAK_URL"
    echo "  - Admin credentials are correct: $KEYCLOAK_ADMIN_USER/***"
    exit 1
fi

echo "✅ Successfully obtained access token"
echo ""
echo "Creating OpenShift realm..."

REALM_RESPONSE=$(curl $CURL_OPTS -w "%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/realm/realm-create.json")

REALM_CODE=$(echo "$REALM_RESPONSE" | tail -c 4)

if [ "$REALM_CODE" = "201" ] || [ "$REALM_CODE" = "409" ]; then
    if [ "$REALM_CODE" = "201" ]; then echo "✅ OpenShift realm created"
    else echo "✅ OpenShift realm already exists"; fi
else
    echo "❌ Failed to create OpenShift realm (HTTP $REALM_CODE)"
    exit 1
fi

echo ""
echo "Configuring realm events..."

EVENT_CONFIG_RESPONSE=$(curl $CURL_OPTS -w "HTTPCODE:%{http_code}" -X PUT "$KEYCLOAK_URL/admin/realms/openshift" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/realm/realm-events-config.json")

EVENT_CONFIG_CODE=$(echo "$EVENT_CONFIG_RESPONSE" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)

if [ "$EVENT_CONFIG_CODE" = "204" ]; then
    echo "✅ User and admin event logging enabled"
else
    echo "⚠️  Could not configure event logging (HTTP $EVENT_CONFIG_CODE)"
fi

echo ""
echo "Creating mcp:openshift client scope..."

SCOPE_RESPONSE=$(curl $CURL_OPTS -w "HTTPCODE:%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/openshift/client-scopes" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/client-scopes/mcp-openshift.json")

SCOPE_CODE=$(echo "$SCOPE_RESPONSE" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)

if [ "$SCOPE_CODE" = "201" ] || [ "$SCOPE_CODE" = "409" ]; then
    if [ "$SCOPE_CODE" = "201" ]; then echo "✅ mcp:openshift client scope created"
    else echo "✅ mcp:openshift client scope already exists"; fi
else
    echo "❌ Failed to create mcp:openshift scope (HTTP $SCOPE_CODE)"
    exit 1
fi

echo ""
echo "Adding audience mapper to mcp:openshift scope..."

SCOPES_LIST=$(curl $CURL_OPTS -X GET "$KEYCLOAK_URL/admin/realms/openshift/client-scopes" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json")

SCOPE_ID=$(echo "$SCOPES_LIST" | jq -r '.[] | select(.name == "mcp:openshift") | .id // empty' 2>/dev/null)

if [ -z "$SCOPE_ID" ]; then
    echo "❌ Failed to find mcp:openshift scope"
    exit 1
fi

MAPPER_RESPONSE=$(curl $CURL_OPTS -w "HTTPCODE:%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/openshift/client-scopes/$SCOPE_ID/protocol-mappers/models" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/mappers/openshift-audience.json")

MAPPER_CODE=$(echo "$MAPPER_RESPONSE" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)

if [ "$MAPPER_CODE" = "201" ] || [ "$MAPPER_CODE" = "409" ]; then
    if [ "$MAPPER_CODE" = "201" ]; then echo "✅ Audience mapper added"
    else echo "✅ Audience mapper already exists"; fi
else
    echo "❌ Failed to create audience mapper (HTTP $MAPPER_CODE)"
    exit 1
fi

echo ""
echo "Creating groups client scope..."

GROUPS_SCOPE_RESPONSE=$(curl $CURL_OPTS -w "HTTPCODE:%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/openshift/client-scopes" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/client-scopes/groups.json")

GROUPS_SCOPE_CODE=$(echo "$GROUPS_SCOPE_RESPONSE" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)

if [ "$GROUPS_SCOPE_CODE" = "201" ] || [ "$GROUPS_SCOPE_CODE" = "409" ]; then
    if [ "$GROUPS_SCOPE_CODE" = "201" ]; then echo "✅ groups client scope created"
    else echo "✅ groups client scope already exists"; fi
else
    echo "❌ Failed to create groups scope (HTTP $GROUPS_SCOPE_CODE)"
    exit 1
fi

echo ""
echo "Adding group membership mapper to groups scope..."

SCOPES_LIST=$(curl $CURL_OPTS -X GET "$KEYCLOAK_URL/admin/realms/openshift/client-scopes" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json")

GROUPS_SCOPE_ID=$(echo "$SCOPES_LIST" | jq -r '.[] | select(.name == "groups") | .id // empty' 2>/dev/null)

if [ -z "$GROUPS_SCOPE_ID" ]; then
    echo "❌ Failed to find groups scope"
    exit 1
fi

GROUPS_MAPPER_RESPONSE=$(curl $CURL_OPTS -w "HTTPCODE:%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/openshift/client-scopes/$GROUPS_SCOPE_ID/protocol-mappers/models" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/mappers/groups-membership.json")

GROUPS_MAPPER_CODE=$(echo "$GROUPS_MAPPER_RESPONSE" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)

if [ "$GROUPS_MAPPER_CODE" = "201" ] || [ "$GROUPS_MAPPER_CODE" = "409" ]; then
    if [ "$GROUPS_MAPPER_CODE" = "201" ]; then echo "✅ Group membership mapper added"
    else echo "✅ Group membership mapper already exists"; fi
else
    echo "❌ Failed to create group mapper (HTTP $GROUPS_MAPPER_CODE)"
    exit 1
fi

echo ""
echo "Creating mcp-server client scope..."

MCP_SERVER_SCOPE_RESPONSE=$(curl $CURL_OPTS -w "HTTPCODE:%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/openshift/client-scopes" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/client-scopes/mcp-server.json")

MCP_SERVER_SCOPE_CODE=$(echo "$MCP_SERVER_SCOPE_RESPONSE" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)

if [ "$MCP_SERVER_SCOPE_CODE" = "201" ] || [ "$MCP_SERVER_SCOPE_CODE" = "409" ]; then
    if [ "$MCP_SERVER_SCOPE_CODE" = "201" ]; then echo "✅ mcp-server client scope created"
    else echo "✅ mcp-server client scope already exists"; fi
else
    echo "❌ Failed to create mcp-server scope (HTTP $MCP_SERVER_SCOPE_CODE)"
    exit 1
fi

echo ""
echo "Adding audience mapper to mcp-server scope..."

SCOPES_LIST=$(curl $CURL_OPTS -X GET "$KEYCLOAK_URL/admin/realms/openshift/client-scopes" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json")

MCP_SERVER_SCOPE_ID=$(echo "$SCOPES_LIST" | jq -r '.[] | select(.name == "mcp-server") | .id // empty' 2>/dev/null)

if [ -z "$MCP_SERVER_SCOPE_ID" ]; then
    echo "❌ Failed to find mcp-server scope"
    exit 1
fi

MCP_SERVER_MAPPER_RESPONSE=$(curl $CURL_OPTS -w "HTTPCODE:%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/openshift/client-scopes/$MCP_SERVER_SCOPE_ID/protocol-mappers/models" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/mappers/mcp-server-audience.json")

MCP_SERVER_MAPPER_CODE=$(echo "$MCP_SERVER_MAPPER_RESPONSE" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)

if [ "$MCP_SERVER_MAPPER_CODE" = "201" ] || [ "$MCP_SERVER_MAPPER_CODE" = "409" ]; then
    if [ "$MCP_SERVER_MAPPER_CODE" = "201" ]; then echo "✅ mcp-server audience mapper added"
    else echo "✅ mcp-server audience mapper already exists"; fi
else
    echo "❌ Failed to create mcp-server audience mapper (HTTP $MCP_SERVER_MAPPER_CODE)"
    exit 1
fi

echo ""
echo "Creating openshift service client..."

OPENSHIFT_CLIENT_RESPONSE=$(curl $CURL_OPTS -w "HTTPCODE:%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/openshift/clients" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/clients/openshift.json")

OPENSHIFT_CLIENT_CODE=$(echo "$OPENSHIFT_CLIENT_RESPONSE" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)

if [ "$OPENSHIFT_CLIENT_CODE" = "201" ] || [ "$OPENSHIFT_CLIENT_CODE" = "409" ]; then
    if [ "$OPENSHIFT_CLIENT_CODE" = "201" ]; then echo "✅ openshift client created"
    else echo "✅ openshift client already exists"; fi
else
    echo "❌ Failed to create openshift client (HTTP $OPENSHIFT_CLIENT_CODE)"
    exit 1
fi

echo ""
echo "Adding username mapper to openshift client..."

OPENSHIFT_CLIENTS_LIST=$(curl $CURL_OPTS -X GET "$KEYCLOAK_URL/admin/realms/openshift/clients" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json")

OPENSHIFT_CLIENT_ID=$(echo "$OPENSHIFT_CLIENTS_LIST" | jq -r '.[] | select(.clientId == "openshift") | .id // empty' 2>/dev/null)

OPENSHIFT_USERNAME_MAPPER_RESPONSE=$(curl $CURL_OPTS -w "HTTPCODE:%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/openshift/clients/$OPENSHIFT_CLIENT_ID/protocol-mappers/models" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/mappers/username.json")

OPENSHIFT_USERNAME_MAPPER_CODE=$(echo "$OPENSHIFT_USERNAME_MAPPER_RESPONSE" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)

if [ "$OPENSHIFT_USERNAME_MAPPER_CODE" = "201" ] || [ "$OPENSHIFT_USERNAME_MAPPER_CODE" = "409" ]; then
    if [ "$OPENSHIFT_USERNAME_MAPPER_CODE" = "201" ]; then echo "✅ Username mapper added to openshift client"
    else echo "✅ Username mapper already exists on openshift client"; fi
else
    echo "❌ Failed to create username mapper (HTTP $OPENSHIFT_USERNAME_MAPPER_CODE)"
    exit 1
fi

echo ""
echo "Creating mcp-client public client..."

MCP_PUBLIC_CLIENT_RESPONSE=$(curl $CURL_OPTS -w "HTTPCODE:%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/openshift/clients" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/clients/mcp-client.json")

MCP_PUBLIC_CLIENT_CODE=$(echo "$MCP_PUBLIC_CLIENT_RESPONSE" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)

if [ "$MCP_PUBLIC_CLIENT_CODE" = "201" ] || [ "$MCP_PUBLIC_CLIENT_CODE" = "409" ]; then
    if [ "$MCP_PUBLIC_CLIENT_CODE" = "201" ]; then echo "✅ mcp-client public client created"
    else echo "✅ mcp-client public client already exists"; fi
else
    echo "❌ Failed to create mcp-client public client (HTTP $MCP_PUBLIC_CLIENT_CODE)"
    exit 1
fi

echo ""
echo "Adding username mapper to mcp-client..."

MCP_PUBLIC_CLIENTS_LIST=$(curl $CURL_OPTS -X GET "$KEYCLOAK_URL/admin/realms/openshift/clients" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json")

MCP_PUBLIC_CLIENT_ID=$(echo "$MCP_PUBLIC_CLIENTS_LIST" | jq -r '.[] | select(.clientId == "mcp-client") | .id // empty' 2>/dev/null)

MCP_PUBLIC_USERNAME_MAPPER_RESPONSE=$(curl $CURL_OPTS -w "HTTPCODE:%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/openshift/clients/$MCP_PUBLIC_CLIENT_ID/protocol-mappers/models" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/mappers/username.json")

MCP_PUBLIC_USERNAME_MAPPER_CODE=$(echo "$MCP_PUBLIC_USERNAME_MAPPER_RESPONSE" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)

if [ "$MCP_PUBLIC_USERNAME_MAPPER_CODE" = "201" ] || [ "$MCP_PUBLIC_USERNAME_MAPPER_CODE" = "409" ]; then
    if [ "$MCP_PUBLIC_USERNAME_MAPPER_CODE" = "201" ]; then echo "✅ Username mapper added to mcp-client"
    else echo "✅ Username mapper already exists on mcp-client"; fi
else
    echo "❌ Failed to create username mapper (HTTP $MCP_PUBLIC_USERNAME_MAPPER_CODE)"
    exit 1
fi

echo ""
echo "Creating mcp-server client with token exchange..."

MCP_CLIENT_RESPONSE=$(curl $CURL_OPTS -w "HTTPCODE:%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/openshift/clients" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/clients/mcp-server.json")

MCP_CLIENT_CODE=$(echo "$MCP_CLIENT_RESPONSE" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)

if [ "$MCP_CLIENT_CODE" = "201" ] || [ "$MCP_CLIENT_CODE" = "409" ]; then
    if [ "$MCP_CLIENT_CODE" = "201" ]; then echo "✅ mcp-server client created"
    else echo "✅ mcp-server client already exists"; fi
else
    echo "❌ Failed to create mcp-server client (HTTP $MCP_CLIENT_CODE)"
    exit 1
fi

echo ""
echo "Enabling standard token exchange for mcp-server..."

CLIENTS_LIST=$(curl $CURL_OPTS -X GET "$KEYCLOAK_URL/admin/realms/openshift/clients" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json")

MCP_CLIENT_ID=$(echo "$CLIENTS_LIST" | jq -r '.[] | select(.clientId == "mcp-server") | .id // empty' 2>/dev/null)

if [ -z "$MCP_CLIENT_ID" ]; then
    echo "❌ Failed to find mcp-server client"
    exit 1
fi

UPDATE_CLIENT_RESPONSE=$(curl $CURL_OPTS -w "HTTPCODE:%{http_code}" -X PUT "$KEYCLOAK_URL/admin/realms/openshift/clients/$MCP_CLIENT_ID" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/clients/mcp-server-update.json")

UPDATE_CLIENT_CODE=$(echo "$UPDATE_CLIENT_RESPONSE" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)

if [ "$UPDATE_CLIENT_CODE" = "204" ]; then
    echo "✅ Standard token exchange enabled for mcp-server client"
else
    echo "⚠️  Could not enable token exchange (HTTP $UPDATE_CLIENT_CODE)"
fi

echo ""
echo "Getting mcp-server client secret..."

SECRET_RESPONSE=$(curl $CURL_OPTS -X GET "$KEYCLOAK_URL/admin/realms/openshift/clients/$MCP_CLIENT_ID/client-secret" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json")

CLIENT_SECRET=$(echo "$SECRET_RESPONSE" | jq -r '.value // empty' 2>/dev/null)

if [ -z "$CLIENT_SECRET" ]; then
    echo "❌ Failed to get client secret"
else
    echo "✅ Client secret retrieved"
fi

echo ""
echo "Adding username mapper to mcp-server client..."

MCP_USERNAME_MAPPER_RESPONSE=$(curl $CURL_OPTS -w "HTTPCODE:%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/openshift/clients/$MCP_CLIENT_ID/protocol-mappers/models" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/mappers/username.json")

MCP_USERNAME_MAPPER_CODE=$(echo "$MCP_USERNAME_MAPPER_RESPONSE" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)

if [ "$MCP_USERNAME_MAPPER_CODE" = "201" ] || [ "$MCP_USERNAME_MAPPER_CODE" = "409" ]; then
    if [ "$MCP_USERNAME_MAPPER_CODE" = "201" ]; then echo "✅ Username mapper added to mcp-server client"
    else echo "✅ Username mapper already exists on mcp-server client"; fi
else
    echo "❌ Failed to create username mapper (HTTP $MCP_USERNAME_MAPPER_CODE)"
    exit 1
fi

echo ""
echo "Creating test user mcp/mcp..."

USER_RESPONSE=$(curl $CURL_OPTS -w "%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/openshift/users" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$KEYCLOAK_CONFIG_DIR/users/mcp.json")

USER_CODE=$(echo "$USER_RESPONSE" | tail -c 4)

if [ "$USER_CODE" = "201" ] || [ "$USER_CODE" = "409" ]; then
    if [ "$USER_CODE" = "201" ]; then echo "✅ mcp user created"
    else echo "✅ mcp user already exists"; fi
else
    echo "❌ Failed to create mcp user (HTTP $USER_CODE)"
    exit 1
fi

echo ""
echo "Setting up RBAC for mcp user..."

RBAC_FILE="$REPO_ROOT/dev/config/openshift/rbac.yaml"
if kubectl apply -f "$RBAC_FILE" 2>/dev/null; then
    echo "✅ RBAC binding created for mcp user"
else
    echo "⚠️  Could not create RBAC binding (kubectl not available or cluster not accessible)"
    echo "   You can manually create it later with: kubectl apply -f $RBAC_FILE"
fi

echo ""
echo "🎉 OpenShift realm setup complete!"
echo ""
echo "========================================"
echo "Configuration Summary"
echo "========================================"
echo "Realm: openshift"
echo "Authorization URL: $KEYCLOAK_URL/realms/openshift"
echo "Issuer URL (for config.toml): $KEYCLOAK_URL/realms/openshift"
echo ""
echo "Test User:"
echo "  Username: mcp"
echo "  Password: mcp"
echo "  Email: mcp@example.com"
echo "  RBAC: cluster-admin (full cluster access)"
echo ""
echo "Clients:"
echo "  mcp-client (public, for browser-based auth)"
echo "    Client ID: mcp-client"
echo "    Optional Scopes: mcp-server, mcp:openshift"
echo "  mcp-server (confidential, token exchange enabled)"
echo "    Client ID: mcp-server"
echo "    Client Secret: $CLIENT_SECRET"
echo "  openshift (service account)"
echo "    Client ID: openshift"
echo ""
echo "Client Scopes:"
echo "  mcp-server (default) - Audience: mcp-server"
echo "  mcp:openshift (optional) - Audience: openshift"
echo "  groups (default) - Group membership mapper"
echo ""
echo "TOML Configuration (config.toml):"
echo "========================================"
echo "require_oauth = true"
echo "oauth_audience = \"mcp-server\""
echo "# Request both scopes to get a token with both audiences (openshift + mcp-server)"
echo "# This avoids the need for token exchange"
echo "oauth_scopes = [\"openid\", \"mcp-server\", \"mcp:openshift\"]"
echo "validate_token = false"
echo "authorization_url = \"$KEYCLOAK_URL/realms/openshift\""
echo ""
echo "# Security Token Service (STS) - Token Exchange Configuration (Optional)"
echo "# Note: Token exchange is not needed if you request both scopes during authentication"
echo "sts_client_id = \"mcp-server\""
echo "sts_client_secret = \"$CLIENT_SECRET\""
echo "sts_audience = \"openshift\""
echo "sts_scopes = [\"mcp:openshift\"]"
echo ""
if [ -n "${KEYCLOAK_CA_CERT:-}" ]; then
    echo "certificate_authority = \"$KEYCLOAK_CA_CERT\""
fi
echo "========================================"
echo ""

# Write configuration to file
echo "Writing configuration to _output/ocp-config.toml..."
mkdir -p "$REPO_ROOT/_output"

# Extract CA certificate if not provided and kubectl is available
if [ -z "${KEYCLOAK_CA_CERT:-}" ] && command -v kubectl >/dev/null 2>&1; then
    echo "  Extracting OpenShift CA certificate..."
    CA_DIR="/tmp/ocp-ca"
    mkdir -p "$CA_DIR"
    if kubectl get configmap -n openshift-config-managed default-ingress-cert -o jsonpath='{.data.ca-bundle\.crt}' > "$CA_DIR/ca-bundle.crt" 2>/dev/null; then
        KEYCLOAK_CA_CERT="$CA_DIR/ca-bundle.crt"
        echo "  ✅ CA certificate extracted to $KEYCLOAK_CA_CERT"
    fi
fi

# Determine kubeconfig path
KUBE_CONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"

cat > "$REPO_ROOT/_output/ocp-config.toml" <<EOF
# OpenShift MCP Server Configuration
# Generated by openshift-keycloak-setup-realm.sh
# Keycloak URL: $KEYCLOAK_URL

# Kubernetes Configuration
kubeconfig = "$KUBE_CONFIG_PATH"

require_oauth = true
oauth_audience = "mcp-server"
# Request both scopes to get a token with both audiences (openshift + mcp-server)
# This avoids the need for token exchange
oauth_scopes = ["openid", "mcp-server", "mcp:openshift"]
validate_token = false
authorization_url = "$KEYCLOAK_URL/realms/openshift"

# Security Token Service (STS) - Token Exchange Configuration (Optional)
# Note: Token exchange is not needed if you request both scopes during authentication
sts_client_id = "mcp-server"
sts_client_secret = "$CLIENT_SECRET"
sts_audience = "openshift"
sts_scopes = ["mcp:openshift"]
EOF

if [ -n "${KEYCLOAK_CA_CERT:-}" ]; then
    echo "" >> "$REPO_ROOT/_output/ocp-config.toml"
    echo "# Certificate Authority for Keycloak TLS verification" >> "$REPO_ROOT/_output/ocp-config.toml"
    echo "certificate_authority = \"$KEYCLOAK_CA_CERT\"" >> "$REPO_ROOT/_output/ocp-config.toml"
fi

echo "✅ Configuration written to _output/ocp-config.toml"
