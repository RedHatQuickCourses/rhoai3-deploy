#!/bin/bash

# =================================================================================
# SCRIPT: deploy-serve.sh
# DESCRIPTION: Production Deployment (Auto-Detects Storage & Fixes Permissions)
# =================================================================================

set -e

# --- CONFIGURATION ---
NAMESPACE="model-deploy-lab"
MODEL_NAME="granite-4-micro"
SERVICE_ACCOUNT="models-sa"
SECRET_NAME="storage-config"
BUCKET_NAME="models"
MODEL_PATH="granite4" # Folder inside the bucket

# --- CREDENTIALS (MUST MATCH FAST-TRACK) ---
ACCESS_KEY="minio"
SECRET_KEY="minio123"

# --- AUTO-DETECT MINIO SERVICE ---
# We look for a service named 'minio' or 'minio-service' to avoid DNS errors.
echo "🔍 Detecting MinIO Service..."
if oc get svc minio -n $NAMESPACE >/dev/null 2>&1; then
    MINIO_HOST="minio.${NAMESPACE}.svc.cluster.local"
    echo "   ✔ Found Service: minio"
elif oc get svc minio-service -n $NAMESPACE >/dev/null 2>&1; then
    MINIO_HOST="minio-service.${NAMESPACE}.svc.cluster.local"
    echo "   ✔ Found Service: minio-service"
else
    echo "   ⚠️  Could not auto-detect MinIO service. Defaulting to 'minio-service'."
    MINIO_HOST="minio-service.${NAMESPACE}.svc.cluster.local"
fi

# Internal URL (HTTP) is faster and safer for pods than the external HTTPS route
MINIO_ENDPOINT="http://${MINIO_HOST}:9000"
echo "   ➤ Using Storage Endpoint: $MINIO_ENDPOINT"

# --- RHOAI OPTIMIZED IMAGE ---
VLLM_IMAGE="registry.redhat.io/rhaiis/vllm-cuda-rhel9@sha256:ad756c01ec99a99cc7d93401c41b8d92ca96fb1ab7c5262919d818f2be4f3768"

echo "🚀 Starting Deployment: $MODEL_NAME"

# ---------------------------------------------------------------------------------
# 1. Configure Data Connection (JSON Format)
# ---------------------------------------------------------------------------------
echo "➤ Configuring Data Connection..."

# Create the JSON structure RHOAI expects
cat <<EOF > /tmp/storage-config.json
{
  "type": "s3",
  "access_key_id": "$ACCESS_KEY",
  "secret_access_key": "$SECRET_KEY",
  "endpoint_url": "$MINIO_ENDPOINT",
  "bucket": "$BUCKET_NAME",
  "region": "us-east-1"
}
EOF

# Update the secret
oc create secret generic "$SECRET_NAME" \
  -n "$NAMESPACE" \
  --from-file=models=/tmp/storage-config.json \
  --dry-run=client -o yaml | oc apply -f -

# Add Dashboard labels
oc label secret "$SECRET_NAME" -n "$NAMESPACE" \
  "opendatahub.io/dashboard=true" "opendatahub.io/managed=true" --overwrite > /dev/null

# ---------------------------------------------------------------------------------
# 2. Configure Service Account
# ---------------------------------------------------------------------------------
echo "➤ Configuring Service Account..."

oc create sa "$SERVICE_ACCOUNT" -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
oc secrets link "$SERVICE_ACCOUNT" "$SECRET_NAME" -n "$NAMESPACE" --for=pull,mount

# Force KServe to use this secret (Bypasses URL matching bugs)
oc annotate sa "$SERVICE_ACCOUNT" -n "$NAMESPACE" \
  serving.kserve.io/secrets="$SECRET_NAME" --overwrite > /dev/null

# ---------------------------------------------------------------------------------
# 3. Define Runtime (Cached Image)
# ---------------------------------------------------------------------------------
echo "➤ Registering vLLM Runtime..."

cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: vllm-runtime
  annotations:
    openshift.io/display-name: vLLM (NVIDIA GPU)
    opendatahub.io/recommended-accelerators: '["nvidia.com/gpu"]'
spec:
  supportedModelFormats:
    - name: vLLM
      autoSelect: true
  containers:
    - name: kserve-container
      image: $VLLM_IMAGE
      command: ["python", "-m", "vllm.entrypoints.openai.api_server"]
      args:
        - "--port=8080"
        - "--model=/mnt/models"
        - "--served-model-name={{.Name}}"
      env:
        - name: HF_HOME
          value: /tmp/hf_home
      ports:
        - containerPort: 8080
          protocol: TCP
      resources:
        requests:
          nvidia.com/gpu: "1"
        limits:
          nvidia.com/gpu: "1"
EOF

# ---------------------------------------------------------------------------------
# 4. Deploy Model
# ---------------------------------------------------------------------------------
echo "➤ Deploying InferenceService..."

cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: $MODEL_NAME
  labels:
    opendatahub.io/dashboard: "true"
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  predictor:
    serviceAccountName: $SERVICE_ACCOUNT
    model:
      modelFormat:
        name: vLLM
      runtime: vllm-runtime
      storageUri: "s3://models/$MODEL_PATH"
      
      args:
        - "--dtype=float16"
        - "--max-model-len=8192" 
        - "--gpu-memory-utilization=0.90" 
      
      resources:
        requests:
          cpu: "2"
          memory: "6Gi"
          nvidia.com/gpu: "1"
        limits:
          cpu: "4"
          memory: "14Gi"
          nvidia.com/gpu: "1" 
EOF

# ---------------------------------------------------------------------------------
# 5. Wait for Success
# ---------------------------------------------------------------------------------
echo "⏳ Waiting for Model to Load..."
for i in {1..30}; do
  STATUS=$(oc get inferenceservice $MODEL_NAME -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [ "$STATUS" == "True" ]; then
    URL=$(oc get inferenceservice $MODEL_NAME -n $NAMESPACE -o jsonpath='{.status.url}')
    echo ""
    echo "✅ SUCCESS: Model is Serving!"
    echo "🔗 Endpoint: $URL/v1/completions"
    exit 0
  fi
  echo -n "."
  sleep 10
done

echo ""
echo "⚠️  Timeout. Check logs: oc logs -n $NAMESPACE -l serving.kserve.io/inferenceservice=$MODEL_NAME -c storage-initializer"