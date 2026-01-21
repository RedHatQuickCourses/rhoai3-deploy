#!/bin/bash

# =================================================================================
# SCRIPT: deploy-serve.sh
# DESCRIPTION: Deploys a vLLM-based InferenceService using the RHOAI Global Runtime.
#              (Matches UI performance by using cached images and optimized profile)
# =================================================================================

set -e

# --- CONFIGURATION ---
NAMESPACE="model-deploy-lab"
MODEL_NAME="granite-4-micro"
SERVICE_ACCOUNT="models-sa" 
SECRET_NAME="storage-config"
MODEL_URI="s3://models/granite4"

echo "🚀 Deploying Model: $MODEL_NAME"

# ---------------------------------------------------------------------------------
# 1. Security Setup
# ---------------------------------------------------------------------------------
echo "➤ Configuring Service Account & Permissions..."

# Create SA if missing
if ! oc get sa "$SERVICE_ACCOUNT" -n "$NAMESPACE" > /dev/null 2>&1; then
    oc create sa "$SERVICE_ACCOUNT" -n "$NAMESPACE"
fi

# Link Secret (Essential for model download)
oc secrets link "$SERVICE_ACCOUNT" "$SECRET_NAME" -n "$NAMESPACE" --for=pull,mount
echo "   ✔ Linked secret to Service Account"

# ---------------------------------------------------------------------------------
# 2. Deploy the Inference Service
# ---------------------------------------------------------------------------------
echo "➤ Creating InferenceService..."

# NOTE: We removed the 'ServingRuntime' definition block. 
# We will point to the existing Global Runtime ('vllm') instead.

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
      
      # USE THE GLOBAL RUNTIME (Matches UI Behavior)
      # This uses the cached 'registry.redhat.io' image instead of pulling a new one
      runtime: vllm 
      
      storageUri: "$MODEL_URI"
      
      args:
        - "--dtype=float16"
        - "--max-model-len=8192" 
        - "--gpu-memory-utilization=0.90" 
      
      # MATCHING UI RESOURCE PROFILE
      # Lower requests = Faster scheduling on busy clusters
      resources:
        requests:
          cpu: "2"          # UI used 2, Script used 4
          memory: "6Gi"     # UI used 6Gi, Script used 8Gi
          nvidia.com/gpu: "1"
        limits:
          cpu: "4"
          memory: "14Gi"    # Matches UI limit
          nvidia.com/gpu: "1" 
EOF

# ---------------------------------------------------------------------------------
# 3. Wait for Readiness
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