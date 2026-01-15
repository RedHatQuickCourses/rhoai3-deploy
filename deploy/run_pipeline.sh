#!/bin/bash
set -e

# --- CONFIGURATION ---
NAMESPACE="rhoai-model-registry-lab"
MODEL_ID="Qwen/Qwen3-0.6B"
# FIX 1: Added http:// protocol explicitly to prevent aiohttp errors
REGISTRY_HOST="http://model-registry-lab.rhoai-model-registries.svc.cluster.local"
MINIO_HOST="minio-service.${NAMESPACE}.svc.cluster.local"
SERVICE_ACCOUNT="model-ingestion-sa"

echo "🚀 Preparing Supply Chain Job for $MODEL_ID..."

# -----------------------------------------------------------------------------
# 1. Create Service Account
# -----------------------------------------------------------------------------
echo "➤ Ensuring ServiceAccount '$SERVICE_ACCOUNT' exists..."
cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT
  labels:
    app: model-supply-chain
EOF

# -----------------------------------------------------------------------------
# 2. Embed the Python Logic (ConfigMap)
# -----------------------------------------------------------------------------
cat <<EOF > ingest_and_register.py
import os
import boto3
from huggingface_hub import snapshot_download
from model_registry import ModelRegistry
from botocore.client import Config

# --- CONFIGURATION ---
MODEL_ID = "${MODEL_ID}"
VERSION = "1.0.0"
S3_BUCKET = "private-models"

# Env vars provided by the Job
REGISTRY_HOST = os.getenv("REGISTRY_HOST")
REGISTRY_PORT = int(os.getenv("REGISTRY_PORT", 8080))
AWS_ACCESS_KEY = os.getenv("AWS_ACCESS_KEY_ID")
AWS_SECRET_KEY = os.getenv("AWS_SECRET_ACCESS_KEY")
S3_ENDPOINT = os.getenv("AWS_S3_ENDPOINT")

def log(msg): print(f"[PIPELINE]: {msg}")

def main():
    # FIX 2: Safety check to ensure protocol is present
    global REGISTRY_HOST
    if not REGISTRY_HOST.startswith("http"):
        REGISTRY_HOST = f"http://{REGISTRY_HOST}"

    print(f"\n=== STEP 1: ACQUIRING ASSETS ===")
    log(f"Downloading '{MODEL_ID}' from Hugging Face...")
    local_dir = snapshot_download(repo_id=MODEL_ID, 
                                  cache_dir="/tmp/hf_cache",
                                  allow_patterns=["*.json", "*.safetensors", "*.model", "tokenizer*"])

    print(f"\n=== STEP 2: SECURING ASSETS (MINIO) ===")
    log(f"Connecting to Vault at {S3_ENDPOINT}...")
    
    s3 = boto3.client('s3',
                      endpoint_url=S3_ENDPOINT,
                      aws_access_key_id=AWS_ACCESS_KEY,
                      aws_secret_access_key=AWS_SECRET_KEY,
                      config=Config(signature_version='s3v4'))
    
    try:
        s3.create_bucket(Bucket=S3_BUCKET)
    except:
        pass 

    # Upload files
    s3_prefix = f"{MODEL_ID.replace('/', '-')}/{VERSION}"
    log(f"Uploading to s3://{S3_BUCKET}/{s3_prefix}...")
    
    for root, dirs, files in os.walk(local_dir):
        for file in files:
            local_path = os.path.join(root, file)
            relative_path = os.path.relpath(local_path, local_dir)
            s3_key = os.path.join(s3_prefix, relative_path)
            s3.upload_file(local_path, S3_BUCKET, s3_key)
            
    s3_uri = f"s3://{S3_BUCKET}/{s3_prefix}"
    log(f"Upload Complete: {s3_uri}")

    print(f"\n=== STEP 3: GOVERNANCE (MODEL REGISTRY) ===")
    log(f"Connecting to Registry at {REGISTRY_HOST}:{REGISTRY_PORT}...")

    # Connect to Registry
    # Note: is_secure=False allows HTTP, but we still need the protocol in the host string
    registry = ModelRegistry(server_address=REGISTRY_HOST, port=REGISTRY_PORT, author="LabUser", is_secure=False)

    log(f"Registering Model: {MODEL_ID}")
    
    model = registry.register_model(
        MODEL_ID,
        s3_uri,
        model_format_name="safetensors",
        model_format_version="1.0",
        version=VERSION,
        description="Qwen3 Small Language Model imported from Hugging Face",
        metadata={
            "source": "huggingface",
            "original_repo": MODEL_ID,
            "license": "Apache 2.0",
            "is_governed": "true"
        }
    )

    print(f"\n✅ SUCCESS: Supply Chain Complete!")
    print(f"    Model ID: {model.id}")
    print(f"    Version: {VERSION}")

if __name__ == "__main__":
    main()
EOF

echo "➤ Creating ConfigMap 'ingestion-code'..."
oc create configmap ingestion-code --from-file=ingest_and_register.py -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
rm ingest_and_register.py

# -----------------------------------------------------------------------------
# 3. Submit the Job
# -----------------------------------------------------------------------------
echo "➤ Submitting Kubernetes Job..."
oc delete job model-ingest-job -n "$NAMESPACE" --ignore-not-found

cat <<YAML | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: model-ingest-job
  namespace: $NAMESPACE
spec:
  backoffLimit: 1
  template:
    spec:
      serviceAccountName: $SERVICE_ACCOUNT
      containers:
      - name: ingestor
        image: registry.access.redhat.com/ubi9/python-311:latest
        command: ["/bin/bash", "-c"]
        args:
          - |
            echo "Installing dependencies..."
            # Using specific range to avoid pypi version errors
            pip install boto3 huggingface-hub "model-registry>=0.2.0,<0.3.0" requests --quiet --no-cache-dir && \
            echo "Starting Ingestion..." && \
            python /scripts/ingest_and_register.py
        volumeMounts:
        - name: code-volume
          mountPath: /scripts
        env:
        - name: REGISTRY_HOST
          value: "$REGISTRY_HOST"
        - name: REGISTRY_PORT
          value: "8080"
        - name: AWS_ACCESS_KEY_ID
          valueFrom:
            secretKeyRef:
              name: aws-connection-minio
              key: AWS_ACCESS_KEY_ID
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom:
            secretKeyRef:
              name: aws-connection-minio
              key: AWS_SECRET_ACCESS_KEY
        - name: AWS_S3_ENDPOINT
          valueFrom:
            secretKeyRef:
              name: aws-connection-minio
              key: AWS_S3_ENDPOINT
      restartPolicy: Never
      volumes:
      - name: code-volume
        configMap:
          name: ingestion-code
YAML

# -----------------------------------------------------------------------------
# 4. Wait for Logs
# -----------------------------------------------------------------------------
echo "⏳ Job submitted. Waiting for Pod to initialize..."

while true; do
  POD_STATUS=$(oc get pods -l job-name=model-ingest-job -n "$NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  if [[ "$POD_STATUS" == "Running" || "$POD_STATUS" == "Succeeded" || "$POD_STATUS" == "Failed" ]]; then
    echo "✔ Pod is ready ($POD_STATUS). Streaming logs..."
    break
  fi
  echo -n "."
  sleep 2
done

oc logs job/model-ingest-job -n "$NAMESPACE" -f