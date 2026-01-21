#!/bin/bash

# =================================================================================
# SCRIPT: deploy-serve.sh
# DESCRIPTION: Deploys a vLLM InferenceService using the Cached Red Hat Image.
#              (Self-contained: Creates SA, Runtime, and Service)
# =================================================================================

set -e

# --- CONFIGURATION ---
NAMESPACE="model-deploy-lab"
MODEL_NAME="granite-4-micro"
SERVICE_ACCOUNT="models-sa"
SECRET_NAME="storage-config"
MODEL_URI="s3://models/granite4"

# ⚡ FAST IMAGE: This is the exact image from your successful UI deployment
# It is likely cached on the nodes, ensuring 3-minute startup times.
VLLM_IMAGE="registry.redhat.io/rhaiis/vllm-cuda-rhel9@sha256:ad756c01ec99a99cc7d93401c41b8d92ca96fb1ab7c5262919d818f2be4f3768"

echo "🚀 Deploying Model: $MODEL_NAME"

# ---------------------------------------------------------------------------------
# 1. Security Setup (Service Account)
# ---------------------------------------------------------------------------------
echo "➤ Configuring Service Account..."

# Create SA if missing
if ! oc get sa "$SERVICE_ACCOUNT" -n "$NAMESPACE" > /dev/null 2>&1; then
    oc create sa "$SERVICE_ACCOUNT" -n "$NAMESPACE"
fi

# Link Secret (Essential for model download)
oc secrets link "$SERVICE_ACCOUNT" "$SECRET_NAME" -n "$NAMESPACE" --for=pull,mount
echo "   ✔ Linked secret to Service Account"

# ---------------------------------------------------------------------------------
# 2. Define the Runtime (The Engine)
# ---------------------------------------------------------------------------------
echo "➤ Configuring Cached vLLM Runtime..."

# We EXPLICITLY define this to avoid "Runtime not found" errors.
# We use the Red Hat image to avoid "10-minute download" delays.

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
# 3. Deploy the Inference Service (The Application)
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
    serviceAccountName: $SERVICE_ACCOUNT
    model:
      modelFormat:
        name: vLLM
      runtime: vllm-runtime  # Points to the local runtime we just created above
      storageUri: "$MODEL_URI"
      
      # 🛠️ ARGUMENTS MATCHING UI 🛠️
      args:
        - "--dtype=float16"
        - "--max-model-len=8192" 
        - "--gpu-memory-utilization=0.90" 
      
      # 🛠️ RESOURCES MATCHING UI 🛠️
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
# 4. Wait for Readiness
# ---------------------------------------------------------------------------------
echo "⏳ Deployment submitted. Waiting for Model to Load..."

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
echo "⚠️  Timeout. Check logs: oc logs -n $NAMESPACE -l serving.kserve.io/inferenceservice=$MODEL_NAME -c kserve-container"