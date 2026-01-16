#!/bin/bash

# =================================================================================
# SCRIPT: deploy-serve.sh
# ZONE: 3 (Serving & Inference)
# DESCRIPTION: Deploys a vLLM-based InferenceService with tuned KV-Cache limits.
#              1. Creates/Updates the vLLM ServingRuntime.
#              2. Deploys the InferenceService pointing to S3.
# =================================================================================

set -e

# --- CONFIGURATION ---
NAMESPACE="rhoai-model-vllm-lab"
MODEL_NAME="granite-4-micro"
# The path must match what was uploaded in the fast-track or pipeline script
# Note: KServe expects the folder *containing* the weights, not the file itself.
MODEL_PATH="ibm-granite/granite-4-micro" 
DATA_CONNECTION="aws-connection-minio"
CONTEXT_LIMIT="16000" # Requested KV Cache / Context Limit

echo "🚀 Deploying Model: $MODEL_NAME"
echo "📏 Enforcing Context Limit: $CONTEXT_LIMIT tokens"

# ---------------------------------------------------------------------------------
# Prerequisites Check
# ---------------------------------------------------------------------------------
echo "----------------------------------------------------------------"
echo "Checking Prerequisites..."

# Check Namespace
if ! oc get project "$NAMESPACE" > /dev/null 2>&1; then
    echo "➤ Creating namespace $NAMESPACE..."
    oc new-project "$NAMESPACE"
else
    echo "✔ Namespace $NAMESPACE exists."
fi

# Check Data Connection exists
if ! oc get secret "$DATA_CONNECTION" -n "$NAMESPACE" > /dev/null 2>&1; then
    echo "❌ Error: Data Connection '$DATA_CONNECTION' not found in namespace '$NAMESPACE'"
    echo "   Run fast-track.sh first to create the data connection."
    exit 1
else
    echo "✔ Data Connection '$DATA_CONNECTION' found."
fi

echo "----------------------------------------------------------------"

# ---------------------------------------------------------------------------------
# 1. Define the Serving Runtime (The Engine)
# ---------------------------------------------------------------------------------
# We use vLLM, the standard for high-performance inference in RHOAI.
# We ensure the runtime listens on the correct ports for KServe.
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
      image: quay.io/modh/vllm:rhoai-2.13 # Use valid RHOAI vLLM image
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
          cpu: "4"
          memory: "8Gi"
        limits:
          cpu: "8"
          memory: "16Gi"
          nvidia.com/gpu: "1"
  multiModel: false
  supportedModelFormats:
    - autoSelect: true
      name: vLLM
EOF

# ---------------------------------------------------------------------------------
# 2. Deploy the Inference Service (The Application)
# ---------------------------------------------------------------------------------
# This binds the storage (S3) to the runtime and applies the tuning args.
echo "➤ Creating InferenceService..."

cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: $MODEL_NAME
  annotations:
    # Sidecar injection is handled by the operator, but we ensure mesh is ready
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
        - "--dtype=float16"           # Force FP16 for speed/memory balance
        - "--max-model-len=$CONTEXT_LIMIT" # The KV Cache Limit (16k)
        - "--gpu-memory-utilization=0.95"  # Reserve 95% of VRAM for weights+cache
      resources:
        requests:
          cpu: "2"
          memory: "8Gi"
          nvidia.com/gpu: "1"
        limits:
          cpu: "4"
          memory: "16Gi"
          nvidia.com/gpu: "1" 
EOF

# ---------------------------------------------------------------------------------
# 3. Wait for Readiness
# ---------------------------------------------------------------------------------
echo "⏳ Deployment submitted. Waiting for KServe to load weights (approx 2-5 mins)..."

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
    echo "  -d '{\"model\": \"$MODEL_NAME\", \"prompt\": \"Define latency in AI.\", \"max_tokens\": 50}'"
    exit 0
  fi
  
  echo -n "."
  sleep 10
done

echo ""
echo "⚠️  Timeout waiting for model. Check logs with:"
echo "oc logs -n $NAMESPACE -l serving.kserve.io/inferenceservice=$MODEL_NAME -c kserve-container"