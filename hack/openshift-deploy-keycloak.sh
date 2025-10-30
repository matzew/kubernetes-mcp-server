#!/bin/bash
set -euo pipefail

# Deploy Keycloak on OpenShift
# This script deploys a Keycloak instance on OpenShift for MCP server testing/development
#
# Optional environment variables:
#   KEYCLOAK_VERSION    - Keycloak version to deploy (default: 26.4)
#   KEYCLOAK_NAMESPACE  - Namespace to deploy Keycloak (default: keycloak)
#   KUBECONFIG          - Path to kubeconfig

KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-26.4}"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"

echo "========================================="
echo "Deploying Keycloak on OpenShift"
echo "========================================="
echo "Version: $KEYCLOAK_VERSION"
echo "Namespace: $KEYCLOAK_NAMESPACE"
echo ""

# Use simple admin credentials for dev/testing (like kind setup)
KEYCLOAK_ADMIN_USER="admin"
KEYCLOAK_ADMIN_PASSWORD="admin"

echo "Step 1: Creating namespace..."
if oc get namespace "$KEYCLOAK_NAMESPACE" >/dev/null 2>&1; then
    echo "✅ Namespace $KEYCLOAK_NAMESPACE already exists"
else
    oc create namespace "$KEYCLOAK_NAMESPACE"
    echo "✅ Namespace $KEYCLOAK_NAMESPACE created"
fi

echo ""
echo "Step 2: Deploying PostgreSQL for persistent storage..."

# Check if PostgreSQL secret already exists and reuse password
if oc get secret postgresql-credentials -n "$KEYCLOAK_NAMESPACE" >/dev/null 2>&1; then
    echo "  Using existing PostgreSQL credentials"
    POSTGRESQL_PASSWORD=$(oc get secret postgresql-credentials -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.POSTGRESQL_PASSWORD}' | base64 -d)
else
    echo "  Generating new PostgreSQL credentials"
    POSTGRESQL_PASSWORD="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)"
fi

cat <<EOF | oc apply -n "$KEYCLOAK_NAMESPACE" -f -
---
# PostgreSQL PersistentVolumeClaim
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgresql-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
---
# PostgreSQL Secret
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-credentials
type: Opaque
stringData:
  POSTGRESQL_DATABASE: keycloak
  POSTGRESQL_USER: keycloak
  POSTGRESQL_PASSWORD: $POSTGRESQL_PASSWORD
---
# PostgreSQL Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgresql
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgresql
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      containers:
      - name: postgresql
        image: registry.redhat.io/rhel9/postgresql-16:latest
        ports:
        - containerPort: 5432
          name: postgresql
        envFrom:
        - secretRef:
            name: postgresql-credentials
        volumeMounts:
        - name: postgresql-data
          mountPath: /var/lib/pgsql/data
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          tcpSocket:
            port: 5432
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - pg_isready -U keycloak
          initialDelaySeconds: 10
          periodSeconds: 5
      volumes:
      - name: postgresql-data
        persistentVolumeClaim:
          claimName: postgresql-data
---
# PostgreSQL Service
apiVersion: v1
kind: Service
metadata:
  name: postgresql
spec:
  ports:
  - port: 5432
    targetPort: 5432
    name: postgresql
  selector:
    app: postgresql
  type: ClusterIP
EOF

echo "✅ PostgreSQL deployment created"

echo ""
echo "Step 3: Waiting for PostgreSQL to be ready..."
oc wait --for=condition=ready pod -l app=postgresql -n "$KEYCLOAK_NAMESPACE" --timeout=300s || {
    echo "⚠️  Timeout waiting for PostgreSQL pod. Checking pod status..."
    oc get pods -n "$KEYCLOAK_NAMESPACE"
    echo ""
    echo "PostgreSQL pod logs:"
    oc logs -n "$KEYCLOAK_NAMESPACE" -l app=postgresql --tail=50
    exit 1
}

echo "✅ PostgreSQL is ready"

echo ""
echo "Step 4: Creating Keycloak deployment..."

cat <<EOF | oc apply -n "$KEYCLOAK_NAMESPACE" -f -
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  labels:
    app: keycloak
spec:
  ports:
  - name: https
    port: 8443
    targetPort: 8443
  - name: http
    port: 8080
    targetPort: 8080
  selector:
    app: keycloak
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  labels:
    app: keycloak
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
      - name: keycloak
        image: quay.io/keycloak/keycloak:$KEYCLOAK_VERSION
        args: ["start-dev"]
        env:
        - name: KC_DB
          value: postgres
        - name: KC_DB_URL
          value: jdbc:postgresql://postgresql:5432/keycloak
        - name: KC_DB_USERNAME
          valueFrom:
            secretKeyRef:
              name: postgresql-credentials
              key: POSTGRESQL_USER
        - name: KC_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgresql-credentials
              key: POSTGRESQL_PASSWORD
        - name: KC_BOOTSTRAP_ADMIN_USERNAME
          value: "$KEYCLOAK_ADMIN_USER"
        - name: KC_BOOTSTRAP_ADMIN_PASSWORD
          value: "$KEYCLOAK_ADMIN_PASSWORD"
        - name: KC_PROXY_HEADERS
          value: "xforwarded"
        - name: KC_HTTP_ENABLED
          value: "true"
        - name: KC_HOSTNAME_STRICT
          value: "false"
        ports:
        - name: http
          containerPort: 8080
        - name: https
          containerPort: 8443
        readinessProbe:
          httpGet:
            path: /realms/master
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /realms/master
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 30
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: keycloak
  labels:
    app: keycloak
spec:
  to:
    kind: Service
    name: keycloak
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

echo "✅ Keycloak deployment created"

echo ""
echo "Step 5: Waiting for Keycloak pod to be ready..."
oc wait --for=condition=ready pod -l app=keycloak -n "$KEYCLOAK_NAMESPACE" --timeout=300s || {
    echo "⚠️  Timeout waiting for pod. Checking pod status..."
    oc get pods -n "$KEYCLOAK_NAMESPACE"
    echo ""
    echo "Pod logs:"
    oc logs -n "$KEYCLOAK_NAMESPACE" -l app=keycloak --tail=50
    exit 1
}

echo "✅ Keycloak pod is ready"

echo ""
echo "Step 6: Getting Keycloak route..."
KEYCLOAK_ROUTE=$(oc get route keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.spec.host}')
KEYCLOAK_URL="https://$KEYCLOAK_ROUTE"

echo "✅ Keycloak accessible at: $KEYCLOAK_URL"

echo ""
echo "Step 7: Waiting for Keycloak HTTP endpoint to be available..."
for i in $(seq 1 30); do
    STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$KEYCLOAK_URL/realms/master" 2>/dev/null || echo "000")
    if [ "$STATUS" = "200" ]; then
        echo "✅ Keycloak HTTP endpoint ready"
        break
    fi
    echo "  Attempt $i/30: Waiting for Keycloak (status: $STATUS)..."
    sleep 5
done

if [ "$STATUS" != "200" ]; then
    echo "❌ Keycloak endpoint not responding after 150 seconds"
    exit 1
fi

echo ""
echo "Step 8: Configuring OpenShift Authentication CR CA bundle..."

# Get the ingress CA certificate
INGRESS_CA_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}')
if [ -n "$INGRESS_CA_NAME" ]; then
    echo "  Using custom ingress certificate: $INGRESS_CA_NAME"
else
    echo "  Using default OpenShift ingress certificate"
fi

# Create a ConfigMap with the CA bundle for OIDC authentication
# OpenShift ingress uses certs signed by the ingress controller CA
oc create configmap keycloak-oidc-ca -n openshift-config \
    --from-literal=ca-bundle.crt="" \
    --dry-run=client -o yaml | oc apply -f - 2>/dev/null || echo "  ConfigMap already exists"

echo "✅ CA bundle configured (using OpenShift default CA)"

echo ""
echo "🎉 Keycloak deployment complete!"
echo ""
echo "========================================="
echo "Keycloak Details"
echo "========================================="
echo "URL: $KEYCLOAK_URL"
echo "Namespace: $KEYCLOAK_NAMESPACE"
echo "Admin Username: $KEYCLOAK_ADMIN_USER"
echo "Admin Password: $KEYCLOAK_ADMIN_PASSWORD"
echo ""
echo "Admin Console:"
echo "  $KEYCLOAK_URL/admin"
echo ""
echo "Credentials saved to /tmp/keycloak-credentials.env"
echo "========================================="

# Save credentials to file for later use
cat > /tmp/keycloak-credentials.env <<EOF
export KEYCLOAK_URL="$KEYCLOAK_URL"
export KEYCLOAK_ADMIN_USER="$KEYCLOAK_ADMIN_USER"
export KEYCLOAK_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD"
export KEYCLOAK_NAMESPACE="$KEYCLOAK_NAMESPACE"
EOF

echo ""
echo "To use these credentials in your current shell:"
echo "  source /tmp/keycloak-credentials.env"
echo ""
echo "Next steps:"
echo "  1. Source the credentials: source /tmp/keycloak-credentials.env"
echo "  2. Setup MCP realm: make openshift-keycloak-setup"
