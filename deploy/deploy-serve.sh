#!/bin/bash

# =================================================================================
# SCRIPT: deploy-serve.sh
# DESCRIPTION: Deploys a vLLM-based InferenceService with tuned KV-Cache limits.
# =================================================================================

set -e

# --- CONFIGURATION ---
NAMESPACE="model-deploy-lab"
MODEL_NAME="granite-4-micro"
# Path must match the S3 Folder used in fast-track.sh
MODEL_PATH="granite4" 
# Use storage-config as this is what KServe webhook expects
DATA_CONNECTION="storage-config"
CONTEXT_LIMIT="8192" # Tuned for Micro/Small GPU footprint

echo "🚀 Deploying Model: $MODEL_NAME"
echo "📏 Enforcing Context Limit: $CONTEXT_LIMIT tokens"

# ---------------------------------------------------------------------------------
# Prerequisites Check
# ---------------------------------------------------------------------------------
if ! oc get secret "$DATA_CONNECTION" -n "$NAMESPACE" > /dev/null 2>&1; then
    echo "❌ Error: Data Connection '$DATA_CONNECTION' not found in '$NAMESPACE'."
    echo "   Run fast-track.sh first to create the storage-config secret."
    exit 1
fi

# Verify the secret has required keys
echo "➤ Verifying storage secret configuration..."
REQUIRED_KEYS=("AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_S3_ENDPOINT" "AWS_S3_BUCKET")
for KEY in "${REQUIRED_KEYS[@]}"; do
    if ! oc get secret "$DATA_CONNECTION" -n "$NAMESPACE" -o jsonpath="{.data.$KEY}" > /dev/null 2>&1; then
        echo "⚠️  Warning: Secret '$DATA_CONNECTION' missing key '$KEY'"
    fi
done

# ---------------------------------------------------------------------------------
# 1. Define the Serving Runtime (The Engine)
# ---------------------------------------------------------------------------------
echo "➤ Configuring vLLM Runtime..."

cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: vllm-runtime
  labels:
    opendatahub.io/dashboard: "true"
spec:
  annotations:
    prometheus.io/path: /metrics
    prometheus.io/port: "8080"
  containers:
    - name: kserve-container
      image: quay.io/modh/vllm:rhoai-2.13
      command: ["python", "-m", "vllm.entrypoints.openai.api_server"]
      args:
        - "--port=8080"
        - "--model=/mnt/models"
        - "--served-model-name=$MODEL_NAME"
        - "--distributed-executor-backend=mp"
      env:
        - name: HF_HOME
          value: /tmp/hf_home
      ports:
        - containerPort: 8080
          protocol: TCP
      resources:
        requests:
          cpu: "2"
          memory: "4Gi"
        limits:
          cpu: "4"
          memory: "8Gi"
          nvidia.com/gpu: "1"
  multiModel: false
  supportedModelFormats:
    - autoSelect: true
      name: vLLM
EOF

# ---------------------------------------------------------------------------------
# 2. Deploy the Inference Service (The Application)
# ---------------------------------------------------------------------------------
echo "➤ Creating InferenceService..."

cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: $MODEL_NAME
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  predictor:
    model:
      modelFormat:
        name: vLLM
      runtime: vllm-runtime
      storage:
        key: $DATA_CONNECTION
        path: $MODEL_PATH
      # 🛠️ PERFORMANCE TUNING 🛠️
      args:
        - "--dtype=float16"
        - "--max-model-len=$CONTEXT_LIMIT" 
        - "--gpu-memory-utilization=0.90" 
      resources:
        requests:
          cpu: "2"
          memory: "4Gi"
          nvidia.com/gpu: "1"
        limits:
          cpu: "4"
          memory: "8Gi"
          nvidia.com/gpu: "1" 
EOF

# ---------------------------------------------------------------------------------
# 3. Wait for Readiness
# ---------------------------------------------------------------------------------
echo "⏳ Deployment submitted. Waiting for Model to Load..."

# Loop to check status
for i in {1..30}; do
  STATUS=$(oc get inferenceservice $MODEL_NAME -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  
  if [ "$STATUS" == "True" ]; then
    URL=$(oc get inferenceservice $MODEL_NAME -n $NAMESPACE -o jsonpath='{.status.url}')
    echo ""
    echo "✅ SUCCESS: Model is Serving!"
    echo "🔗 Endpoint: $URL/v1/completions"
    echo ""
    echo "👉 Test Command:"
    echo "curl -k $URL/v1/completions \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -d '{\"model\": \"$MODEL_NAME\", \"prompt\": \"Write a haiku about deployment.\", \"max_tokens\": 50}'"
    exit 0
  fi
  
  echo -n "."
  sleep 10
done

echo ""
echo "⚠️  Timeout. Check logs: oc logs -n $NAMESPACE -l serving.kserve.io/inferenceservice=$MODEL_NAME -c kserve-container"