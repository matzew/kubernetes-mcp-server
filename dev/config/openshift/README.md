# OpenShift Configuration for MCP Server

This directory contains OpenShift-specific configuration files for setting up the MCP server with Keycloak OIDC authentication.

## Files

- `rbac.yaml` - RBAC ClusterRoleBinding for the `mcp` user with cluster-admin privileges

## Quick Start

### Prerequisites

1. An OpenShift cluster with external OIDC provider support (requires TechPreviewNoUpgrade feature gate for OCP 4.19)
2. `oc` CLI configured to access your cluster
3. Cluster-admin privileges

### Setup - Option 1: Complete Setup from Scratch (Recommended)

If you have a **fresh OpenShift cluster with no Keycloak**, just run:

```bash
make openshift-full-setup
```

This single command will:
- ✅ Deploy Keycloak in the `keycloak` namespace
- ✅ Create the `openshift` realm with all necessary configuration
- ✅ Configure OpenShift Authentication CR to trust Keycloak
- ✅ Create RBAC binding for the `mcp` user

**That's it!** Credentials will be saved to `/tmp/keycloak-credentials.env`

### Setup - Option 2: Using External Keycloak

If you already have a Keycloak instance running, set environment variables and run setup:

```bash
export KEYCLOAK_URL="https://keycloak.example.com"
export KEYCLOAK_ADMIN_USER="admin"
export KEYCLOAK_ADMIN_PASSWORD="password"

# Optional: For custom CA certificates
export KEYCLOAK_CA_CERT="/path/to/ca-bundle.crt"

# Run setup
make openshift-keycloak-setup
```

### Setup - Option 3: Step-by-Step

For more control over the process:

```bash
# Step 1: Deploy Keycloak on OpenShift
make openshift-deploy-keycloak

# Step 2: Load credentials
source /tmp/keycloak-credentials.env

# Step 3: Setup realm and configure OpenShift
make openshift-keycloak-setup
```

### Check Status

```bash
make openshift-status
```

## What Gets Configured

### 1. Keycloak Realm (`openshift`)

- **Clients:**
  - `mcp-server` (confidential) - Token exchange enabled
  - `mcp-client` (public) - For browser-based authentication
  - `openshift` (service account)

- **Client Scopes:**
  - `mcp-server` - Audience: `mcp-server`
  - `mcp:openshift` - Audience: `openshift`
  - `groups` - Group membership mapper

- **Test User:**
  - Username: `mcp`
  - Password: `mcp`
  - Email: `mcp@example.com`

### 2. OpenShift Authentication

The `Authentication` CR is configured with:

```yaml
spec:
  oidcProviders:
  - issuer:
      issuerURL: https://keycloak.example.com/realms/openshift
      audiences: ["openshift", "mcp-server"]
    claimMappings:
      username:
        claim: preferred_username
        prefixPolicy: NoPrefix
```

### 3. RBAC

A ClusterRoleBinding grants the `mcp` user cluster-admin privileges:

```yaml
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: mcp
```

## Token Exchange Flow

1. User authenticates to Keycloak → receives token with `aud: mcp-server`
2. MCP server exchanges token → receives new token with `aud: openshift`
3. MCP server calls Kubernetes API → API server validates token
4. API server maps `preferred_username: mcp` → Kubernetes user `mcp`
5. RBAC grants `mcp` user cluster-admin rights

## Manual Configuration

If you prefer manual setup, see the individual make targets:

```bash
# Setup Keycloak realm only
make openshift-realm-setup

# Configure OpenShift Authentication CR
make openshift-configure-authentication KEYCLOAK_URL=https://keycloak.example.com

# Apply RBAC binding
oc apply -f dev/config/openshift/rbac.yaml
```

## Troubleshooting

### Check Authentication Configuration

```bash
oc get authentication cluster -o yaml
```

### Check RBAC Binding

```bash
oc get clusterrolebinding oidc-mcp-cluster-admin -o yaml
```

### Check API Server Logs

```bash
oc logs -n openshift-kube-apiserver -l app=openshift-kube-apiserver --tail=100
```

### Test Token Exchange

Use the test script from `/tmp/test-token-exchange.sh` to verify token exchange works correctly.
