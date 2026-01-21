#!/bin/bash

# =================================================================================
# SCRIPT: deploy-serve.sh
# DESCRIPTION: "Mirror Match" Deployment.
#              Replicates the EXACT configuration found in the working UI deployment.
# =================================================================================

set -e

# --- CONFIGURATION (Matched to UI Logs) ---
NAMESPACE="model-deploy-lab"
MODEL_NAME="granite-4-micro"
SERVICE_ACCOUNT="models-sa"
# UI used 'models' as the secret name, so we must too.
SECRET_NAME="models"
BUCKET_NAME="models"
MODEL_PATH="granite4" 

# --- CREDENTIALS ---
ACCESS_KEY="minio"
SECRET_KEY="minio123"

# --- 1. DETECT MINIO (Internal Service) ---
# The UI used: http://minio-service.model-deploy-lab.svc.cluster.local:9000
# We auto-detect this to be safe, but default to the UI's known working value.
echo "🔍 Verifying MinIO Service..."
if oc get svc minio-service -n $NAMESPACE >/dev/null 2>&1; then
    MINIO_HOST="minio-service.${NAMESPACE}.svc.cluster.local"
    echo "   ✔ Found Service: minio-service (Matches UI)"
else
    # Fallback if the lab setup varies slightly
    MINIO_HOST="minio.${NAMESPACE}.svc.cluster.local"
    echo "   ⚠️  'minio-service' not found. Using '$MINIO_HOST'"
fi
MINIO_ENDPOINT="http://${MINIO_HOST}:9000"

# --- 2. CLEANUP ---
echo "🧹 Cleaning up previous attempts..."
oc delete inferenceservice $MODEL_NAME -n $NAMESPACE --ignore-not-found
oc delete secret $SECRET_NAME -n $NAMESPACE --ignore-not-found
oc delete sa $SERVICE_ACCOUNT -n $NAMESPACE --ignore-not-found

# --- 3. CREATE SECRET (The UI Way: Env Vars) ---
echo "➤ Creating Secret '$SECRET_NAME'..."

# We reproduce the EXACT keys found in your 'decoded secret' logs.
cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  labels:
    opendatahub.io/dashboard: "true"
    opendatahub.io/managed: "true"
  annotations:
    # This annotation is the 'Glue' that lets KServe find the secret for this endpoint
    serving.kserve.io/s3-endpoint: "$MINIO_HOST:9000"
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "$ACCESS_KEY"
  AWS_SECRET_ACCESS_KEY: "$SECRET_KEY"
  AWS_S3_ENDPOINT: "$MINIO_ENDPOINT"
  AWS_S3_BUCKET: "$BUCKET_NAME"
  AWS_DEFAULT_REGION: "us-east-1"
EOF

# --- 4. CONFIGURE SERVICE ACCOUNT ---
echo "➤ Configuring Service Account '$SERVICE_ACCOUNT'..."
oc create sa "$SERVICE_ACCOUNT" -n "$NAMESPACE"
oc secrets link "$SERVICE_ACCOUNT" "$SECRET_NAME" -n "$NAMESPACE" --for=pull,mount

# --- 5. DEFINE RUNTIME (Cached Image) ---
# Using the Red Hat image you found in the logs to ensure speed.
VLLM_IMAGE="registry.redhat.io/rhaiis/vllm-cuda-rhel9@sha256:ad756c01ec99a99cc7d93401c41b8d92ca96fb1ab7c5262919d818f2be4f3768"

echo "➤ Registering Runtime..."
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

# --- 6. DEPLOY INFERENCE SERVICE ---
echo "➤ Deploying Model (Mirroring UI Config)..."

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
      
      # 🛠️ EXACT MATCH TO YOUR UI LOGS 🛠️
      storage:
        key: $SECRET_NAME   # "models"
        path: $MODEL_PATH   # "granite4"
      
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

# --- 7. MONITOR ---
echo "⏳ Waiting for Model..."
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