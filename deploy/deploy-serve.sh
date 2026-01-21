#!/bin/bash

# =================================================================================
# SCRIPT: deploy-serve.sh
# DESCRIPTION: Production deployment for Granite-4-Micro on OpenShift AI.
#              - configures RHOAI-compatible Data Connection (JSON)
#              - configures dedicated Service Account
#              - deploys cached Red Hat vLLM Runtime
# =================================================================================

set -e

# --- CONFIGURATION ---
NAMESPACE="model-deploy-lab"
MODEL_NAME="granite-4-micro"
SERVICE_ACCOUNT="models-sa"
SECRET_NAME="storage-config"

# MinIO Connection Details (Matches your Fast-Track Lab)
MINIO_ENDPOINT="http://minio-service.${NAMESPACE}.svc.cluster.local:9000"
MINIO_ACCESS="minio"
MINIO_SECRET="minio123"
MINIO_BUCKET="models"
MODEL_PATH="granite4" # Path inside the bucket

# RHOAI 2.13+ Optimized vLLM Image (Cached)
VLLM_IMAGE="registry.redhat.io/rhaiis/vllm-cuda-rhel9@sha256:ad756c01ec99a99cc7d93401c41b8d92ca96fb1ab7c5262919d818f2be4f3768"

echo "🚀 Starting Production Deployment: $MODEL_NAME"

# ---------------------------------------------------------------------------------
# 1. Configure Data Connection (The Fix)
# ---------------------------------------------------------------------------------
# RHOAI requires the secret to be a JSON object to inject it correctly.
# We update the existing secret to match this standard.
echo "➤ Configuring Data Connection..."

cat <<EOF > /tmp/storage-config.json
{
  "type": "s3",
  "access_key_id": "$MINIO_ACCESS",
  "secret_access_key": "$MINIO_SECRET",
  "endpoint_url": "$MINIO_ENDPOINT",
  "bucket": "$MINIO_BUCKET",
  "region": "us-east-1"
}
EOF

# Update the secret using the JSON file. 
# We use the key 'models' to match the bucket name, which helps KServe find it.
oc create secret generic "$SECRET_NAME" \
  -n "$NAMESPACE" \
  --from-file=models=/tmp/storage-config.json \
  --dry-run=client -o yaml | oc apply -f -

# Apply Dashboard labels so it appears correctly in the UI
oc label secret "$SECRET_NAME" -n "$NAMESPACE" \
  "opendatahub.io/dashboard=true" \
  "opendatahub.io/managed=true" \
  --overwrite > /dev/null

echo "   ✔ Data Connection configured (JSON format)."

# ---------------------------------------------------------------------------------
# 2. Configure Service Account
# ---------------------------------------------------------------------------------
echo "➤ Configuring Identity (Service Account)..."

# Ensure the Service Account exists
oc create sa "$SERVICE_ACCOUNT" -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# Link the secret to the Service Account (Standard Permissions)
oc secrets link "$SERVICE_ACCOUNT" "$SECRET_NAME" -n "$NAMESPACE" --for=pull,mount

# Annotate the SA to FORCE the secret mount (Bypasses URL matching issues)
oc annotate sa "$SERVICE_ACCOUNT" -n "$NAMESPACE" \
  serving.kserve.io/secrets="$SECRET_NAME" \
  --overwrite > /dev/null

echo "   ✔ Service Account '$SERVICE_ACCOUNT' configured."

# ---------------------------------------------------------------------------------
# 3. Define Serving Runtime (Cached Image)
# ---------------------------------------------------------------------------------
echo "➤ registering vLLM Runtime..."

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
# 4. Deploy Inference Service
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
      # URI points to the 'models' bucket and 'granite4' folder
      storageUri: "s3://models/$MODEL_PATH"
      
      # 🛠️ ARGUMENTS (Aligned with RHOAI UI defaults) 🛠️
      args:
        - "--dtype=float16"
        - "--max-model-len=8192" 
        - "--gpu-memory-utilization=0.90" 
      
      # 🛠️ RESOURCES (Aligned with your successful deployment) 🛠️
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
# 5. Wait for Readiness
# ---------------------------------------------------------------------------------
echo "⏳ Deployment submitted. Waiting for Model to Load..."

# 5 Minute Timeout Loop
for i in {1..30}; do
  STATUS=$(oc get inferenceservice $MODEL_NAME -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  
  if [ "$STATUS" == "True" ]; then
    URL=$(oc get inferenceservice $MODEL_NAME -n $NAMESPACE -o jsonpath='{.status.url}')
    echo ""
    echo "✅ SUCCESS: Model is Serving!"
    echo "🔗 Endpoint: $URL/v1/completions"
    exit 0
  fi
  
  # Check for failure states in the conditions
  FAIL_MSG=$(oc get inferenceservice $MODEL_NAME -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.status=="False")].message}' 2>/dev/null)
  if [[ ! -z "$FAIL_MSG" && "$FAIL_MSG" != "" ]]; then
      # Only print if it's not a standard "Initializing" message
      if [[ "$FAIL_MSG" != *"ContainerCreating"* && "$FAIL_MSG" != *"PodInitializing"* ]]; then
         echo -n "!"
      else
         echo -n "."
      fi
  else
      echo -n "."
  fi

  sleep 10
done

echo ""
echo "⚠️  Timeout. Run this command to debug:"
echo "oc logs -n $NAMESPACE -l serving.kserve.io/inferenceservice=$MODEL_NAME -c storage-initializer"