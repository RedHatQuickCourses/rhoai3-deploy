#!/bin/bash

# =================================================================================
# SCRIPT: setup.sh
# DESCRIPTION: Automates the "Plumbing" phase of the Model Registry QuickStart.
#              1. Creates the Namespace
#              2. Deploys MinIO (Object Storage)
#              3. Deploys MySQL (Metadata Storage)
#              4. Creates S3 Data Connection for RHOAI
# =================================================================================

set -e # Exit immediately if a command exits with a non-zero status

# Configuration Variables
NAMESPACE="rhoai-model-registry-lab"
MYSQL_USER="admin"
MYSQL_PASSWORD="mysql-admin"
MYSQL_DATABASE="sampledb"
MINIO_ACCESS_KEY="minio"
MINIO_SECRET_KEY="minio123"

echo "🚀 Starting AI Supply Chain Infrastructure Setup..."

# ---------------------------------------------------------------------------------
# 1. Namespace Management
# ---------------------------------------------------------------------------------
echo "----------------------------------------------------------------"
echo "Step 1: Checking Namespace [$NAMESPACE]..."
if oc get project "$NAMESPACE" > /dev/null 2>&1; then
    echo "✔ Namespace $NAMESPACE already exists."
else
    echo "➤ Creating namespace $NAMESPACE..."
    oc new-project "$NAMESPACE"
fi

# ---------------------------------------------------------------------------------
# 2. Deploy MinIO (The Vault)
# ---------------------------------------------------------------------------------
echo "----------------------------------------------------------------"
echo "Step 2: Deploying MinIO Object Storage (The Vault)..."
# We apply the folder containing Deployment, PVC, Service, and Route
if [ -d "deploy/infrastructure/minio" ]; then
    oc apply -f deploy/infrastructure/minio/ -n "$NAMESPACE"
else
    echo "❌ Error: MinIO YAML directory not found!"
    exit 1
fi

# ---------------------------------------------------------------------------------
# 3. Deploy MySQL (The Brain)
# ---------------------------------------------------------------------------------
echo "----------------------------------------------------------------"
echo "Step 3: Deploying MySQL Database (The Brain)..."
# We apply the folder containing Deployment, PVC, Service, and Secret
if [ -d "deploy/infrastructure/mysql" ]; then
    oc apply -f deploy/infrastructure/mysql/ -n "$NAMESPACE"
else
    echo "❌ Error: MySQL YAML directory not found!"
    exit 1
fi

# ---------------------------------------------------------------------------------
# 4. Create Storage Secret (Data Connection)
# ---------------------------------------------------------------------------------
echo "----------------------------------------------------------------"
echo "Step 4: Creating S3 Data Connection..."

# We create a secret with the specific labels required by OpenShift AI to recognize
# it as a "Data Connection". This allows users to easily select it in pipelines.
echo "➤ Creating 'aws-connection-minio' in $NAMESPACE..."

oc create secret generic aws-connection-minio \
    --from-literal=AWS_ACCESS_KEY_ID="$MINIO_ACCESS_KEY" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY" \
    --from-literal=AWS_S3_ENDPOINT="http://minio-service.$NAMESPACE.svc.cluster.local:9000" \
    --from-literal=AWS_DEFAULT_REGION="us-east-1" \
    --from-literal=AWS_S3_BUCKET="private-models" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | \
    oc apply -f -

# Apply the label to make it visible in the RHOAI Dashboard
oc label secret aws-connection-minio \
    "opendatahub.io/dashboard=true" \
    -n "$NAMESPACE" \
    --overwrite

echo "✔ Storage Secret Created. It will appear as 'aws-connection-minio' in the Dashboard."

# ---------------------------------------------------------------------------------
# 5. Summary / Next Steps
# ---------------------------------------------------------------------------------
echo "----------------------------------------------------------------"
echo "✅ Infrastructure Setup Complete!"
echo ""
echo "📝 NEXT STEP: MANUAL DB CONNECTION"
echo "The MySQL Database is running, but the Registry does not have the password yet."
echo "Please execute the following command manually to create the DB secret:"
echo ""
echo "oc create secret generic registry-db-secret \\"
echo "  -n rhoai-model-registries \\"
echo "  --from-literal=database-host='mysql.$NAMESPACE.svc.cluster.local' \\"
echo "  --from-literal=database-port='3306' \\"
echo "  --from-literal=database-name='$MYSQL_DATABASE' \\"
echo "  --from-literal=database-user='$MYSQL_USER' \\"
echo "  --from-literal=database-password='$MYSQL_PASSWORD'"
echo "----------------------------------------------------------------"