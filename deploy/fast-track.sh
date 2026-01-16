#!/bin/bash

# =================================================================================
# SCRIPT: fast_track_serving.sh
# DESCRIPTION: "The Emergency Button." 
#              Sets up (Serving) prerequisites for users who skipped.
#              1. Deploys MinIO (The Vault).
#              2. Creates the RHOAI Data Connection.
#              3. Downloads a model (Ungated) and uploads to MinIO via a K8s Job.
# =================================================================================

set -e

# --- CONFIGURATION ---
NAMESPACE="rhoai-model-vllm-lab"
MODEL_ID="ibm-granite/granite-4.0-micro" # Using 2B for speed, change to 8b if needed
S3_BUCKET="models-secure" # Matching the Serving Lab bucket name
MINIO_ACCESS_KEY="minio"
MINIO_SECRET_KEY="minio123"
SERVICE_ACCOUNT="fast-track-sa"

echo "🚀 Starting Fast-Track Setup for Serving Lab..."
echo "🎯 Target Model: $MODEL_ID (Ungated)"

# ---------------------------------------------------------------------------------
# 1. Namespace & MinIO (The Vault)
# ---------------------------------------------------------------------------------
echo "----------------------------------------------------------------"
echo "Step 1: Checking Infrastructure..."

# Check Namespace
if ! oc get project "$NAMESPACE" > /dev/null 2>&1; then
    echo "➤ Creating namespace $NAMESPACE..."
    oc new-project "$NAMESPACE"
else
    echo "✔ Namespace $NAMESPACE exists."
fi

# Check MinIO
if ! oc get deployment minio -n "$NAMESPACE" > /dev/null 2>&1; then
    echo "➤ Deploying MinIO..."
    # We assume the user has the repo. If not, we could embed YAML here.
    if [ -d "deploy/infrastructure/minio" ]; then
        oc apply -f deploy/infrastructure/minio/ -n "$NAMESPACE"
    else
        echo "⚠️  MinIO folder not found. Attempting inline deployment..."
        # Fallback inline deployment for robustness
        oc new-app minio/minio:RELEASE.2024-01-31T20-20-33Z \
            -e MINIO_ROOT_USER=$MINIO_ACCESS_KEY \
            -e MINIO_ROOT_PASSWORD=$MINIO_SECRET_KEY \
            --name=minio -n "$NAMESPACE"
        oc set probe dc/minio --liveness --readiness -- get-url=http://:9000/minio/health/live
    fi
else
    echo "✔ MinIO is already running."
fi

# ---------------------------------------------------------------------------------
# 2. Data Connection (The Wiring)
# ---------------------------------------------------------------------------------
echo "----------------------------------------------------------------"
echo "Step 2: Wiring RHOAI Data Connection..."

# Matches setup.sh logic [cite: 4]
oc create secret generic aws-connection-minio \
    --from-literal=AWS_ACCESS_KEY_ID="$MINIO_ACCESS_KEY" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY" \
    --from-literal=AWS_S3_ENDPOINT="http://minio.$NAMESPACE.svc.cluster.local:9000" \
    --from-literal=AWS_DEFAULT_REGION="us-east-1" \
    --from-literal=AWS_S3_BUCKET="$S3_BUCKET" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | \
    oc apply -f -

oc label secret aws-connection-minio \
    "opendatahub.io/dashboard=true" \
    -n "$NAMESPACE" \
    --overwrite

echo "✔ Data Connection 'aws-connection-minio' created/updated."

# ---------------------------------------------------------------------------------
# 3. The Ingestion Job (The Loader)
# ---------------------------------------------------------------------------------
echo "----------------------------------------------------------------"
echo "Step 3: Creating Ingestion Job (Download -> S3)..."

# Create Service Account
oc create sa $SERVICE_ACCOUNT -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
oc adm policy add-scc-to-user anyuid -z $SERVICE_ACCOUNT -n "$NAMESPACE" > /dev/null 2>&1

# Create Python Logic (Stripped of Model Registry) 
cat <<EOF > /tmp/fast_ingest.py
import os
import boto3
from huggingface_hub import snapshot_download
from botocore.client import Config

MODEL_ID = "${MODEL_ID}"
S3_BUCKET = "${S3_BUCKET}"
S3_ENDPOINT = os.getenv("AWS_S3_ENDPOINT")
AWS_ACCESS_KEY = os.getenv("AWS_ACCESS_KEY_ID")
AWS_SECRET_KEY = os.getenv("AWS_SECRET_ACCESS_KEY")

def log(msg): print(f"[FAST-TRACK]: {msg}")

def main():
    print(f"\n=== FAST-TRACK: DOWNLOADING {MODEL_ID} ===")
    # Download from HF (Ignore patterns to save space)
    local_dir = snapshot_download(repo_id=MODEL_ID, 
                                  allow_patterns=["*.json", "*.safetensors", "*.model", "tokenizer*"])

    print(f"\n=== FAST-TRACK: UPLOADING TO MINIO ===")
    s3 = boto3.client('s3',
                      endpoint_url=S3_ENDPOINT,
                      aws_access_key_id=AWS_ACCESS_KEY,
                      aws_secret_access_key=AWS_SECRET_KEY,
                      config=Config(signature_version='s3v4'))
    
    # Ensure bucket exists
    try:
        s3.create_bucket(Bucket=S3_BUCKET)
    except Exception as e:
        print(f"Bucket check/create note: {e}")

    # Upload
    s3_prefix = MODEL_ID 
    for root, dirs, files in os.walk(local_dir):
        for file in files:
            local_path = os.path.join(root, file)
            relative_path = os.path.relpath(local_path, local_dir)
            s3_key = os.path.join(s3_prefix, relative_path)
            print(f"Uploading: {s3_key}")
            s3.upload_file(local_path, S3_BUCKET, s3_key)
            
    print(f"\n✅ SUCCESS: Model is ready in bucket '{S3_BUCKET}'.")

if __name__ == "__main__":
    main()
EOF

# Create ConfigMap
oc create configmap fast-track-code --from-file=/tmp/fast_ingest.py -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# Submit Job
oc delete job fast-track-loader -n "$NAMESPACE" --ignore-not-found

cat <<YAML | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: fast-track-loader
  namespace: $NAMESPACE
spec:
  backoffLimit: 2
  template:
    spec:
      serviceAccountName: $SERVICE_ACCOUNT
      containers:
      - name: loader
        image: registry.access.redhat.com/ubi9/python-311:latest
        command: ["/bin/bash", "-c"]
        args:
          - |
            pip install boto3 huggingface-hub --quiet --no-cache-dir && \
            python /scripts/fast_ingest.py
        volumeMounts:
        - name: code-volume
          mountPath: /scripts
        env:
        - name: AWS_ACCESS_KEY_ID
          valueFrom: { secretKeyRef: { name: aws-connection-minio, key: AWS_ACCESS_KEY_ID } }
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom: { secretKeyRef: { name: aws-connection-minio, key: AWS_SECRET_ACCESS_KEY } }
        - name: AWS_S3_ENDPOINT
          valueFrom: { secretKeyRef: { name: aws-connection-minio, key: AWS_S3_ENDPOINT } }
      restartPolicy: Never
      volumes:
      - name: code-volume
        configMap:
          name: fast-track-code
YAML

echo "⏳ Job submitted. Run 'oc logs job/fast-track-loader -n $NAMESPACE -f' to watch progress."