#!/bin/bash

# =================================================================================
# SCRIPT: deploy-serve.sh
# DESCRIPTION: Production Deployment for RHOAI Course.
#              - Defines its own Runtime (Reliability)
#              - Uses Red Hat Cached Images (Speed)
#              - Uses Explicit Secret Wiring (Security)
# =================================================================================

set -e

# --- CONFIGURATION ---
NAMESPACE="model-deploy-lab"
MODEL_NAME="granite-4-micro"
SERVICE_ACCOUNT="models-sa"
SECRET_NAME="models"    # Matches UI convention
BUCKET_NAME="models"
MODEL_PATH="granite4" 

# --- CREDENTIALS ---
ACCESS_KEY="minio"
SECRET_KEY="minio123"

# --- 1. DETECT MINIO (Internal Service) ---
# We auto-detect the internal service name to prevent DNS errors.
if oc get svc minio-service -n $NAMESPACE >/dev/null 2>&1; then
    MINIO_HOST="minio-service.${NAMESPACE}.svc.cluster.local"
else
    MINIO_HOST="minio.${NAMESPACE}.svc.cluster.local"
fi
MINIO_ENDPOINT="http://${MINIO_HOST}:9000"
echo "🔍 Using Storage Endpoint: $MINIO_ENDPOINT"

# --- 2. CLEANUP (Fresh Start) ---
echo "🧹 Cleaning previous deployments..."
oc delete inferenceservice $MODEL_NAME -n $NAMESPACE --ignore-not-found
oc delete servingruntime vllm-runtime -n $NAMESPACE --ignore-not-found
oc delete secret $SECRET_NAME -n $NAMESPACE --ignore-not-found
oc delete sa $SERVICE_ACCOUNT -n $NAMESPACE --ignore-not-found

# --- 3. CREATE SECRET (Env Var Format) ---
echo "➤ Creating Storage Secret..."
# We use the explicit keys found in the UI logs.
cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  labels:
    opendatahub.io/dashboard: "true"
    opendatahub.io/managed: "true"
  annotations:
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
echo "➤ Configuring Service Account..."
oc create sa "$SERVICE_ACCOUNT" -n "$NAMESPACE"
oc secrets link "$SERVICE_ACCOUNT" "$SECRET_NAME" -n "$NAMESPACE" --for=pull,mount

# --- 5. DEFINE RUNTIME (Local Definition = Guaranteed Start) ---
# We define the runtime HERE so we don't depend on global templates matching specific names.
# We use the Red Hat image you successfully pulled earlier.
echo "➤ Registering Local vLLM Runtime..."

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
      # THE GOLDEN IMAGE (Red Hat Cached)
      image: registry.redhat.io/rhaiis/vllm-cuda-rhel9@sha256:ad756c01ec99a99cc7d93401c41b8d92ca96fb1ab7c5262919d818f2be4f3768
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
echo "➤ Deploying Model..."

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
      
      # Points to the LOCAL runtime we just defined above (Guaranteed to exist)
      runtime: vllm-runtime
      
      # EXPLICIT WIRING (Matches UI logs)
      storage:
        key: $SECRET_NAME
        path: $MODEL_PATH
      
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