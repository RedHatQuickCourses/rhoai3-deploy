#!/bin/bash

# =================================================================================
# SCRIPT: deploy-serve.sh
# DESCRIPTION: Production Deployment based on "gemma-3-12b-it" Helm Chart.
#              - Uses exact Image & SHM config from working Helm example.
#              - Adapts storage from OCI to your MinIO S3 bucket.
# =================================================================================

set -e

# --- CONFIGURATION ---
NAMESPACE="model-deploy-lab"
MODEL_NAME="granite-4-micro"
SERVICE_ACCOUNT="models-sa"
SECRET_NAME="models"
BUCKET_NAME="models"
MODEL_PATH="granite4" 

# --- CREDENTIALS ---
ACCESS_KEY="minio"
SECRET_KEY="minio123"

# --- 1. DETECT MINIO SERVICE ---
# Auto-detects internal service name to prevent DNS errors
if oc get svc minio-service -n $NAMESPACE >/dev/null 2>&1; then
    MINIO_HOST="minio-service.${NAMESPACE}.svc.cluster.local"
else
    MINIO_HOST="minio.${NAMESPACE}.svc.cluster.local"
fi
MINIO_ENDPOINT="http://${MINIO_HOST}:9000"
echo "🔍 Using Storage Endpoint: $MINIO_ENDPOINT"

# --- 2. CLEANUP ---
echo "🧹 Cleaning previous deployments..."
oc delete inferenceservice $MODEL_NAME -n $NAMESPACE --ignore-not-found
oc delete servingruntime $MODEL_NAME -n $NAMESPACE --ignore-not-found
oc delete secret $SECRET_NAME -n $NAMESPACE --ignore-not-found
oc delete sa $SERVICE_ACCOUNT -n $NAMESPACE --ignore-not-found

# --- 3. CREATE SECRET (Explicit Env Vars) ---
echo "➤ Creating Storage Secret..."
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

# --- 5. DEFINE RUNTIME (Cloned from Working Helm Chart) ---
# We use the EXACT image and volume configuration from your working example.
echo "➤ Registering Runtime..."

cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: $MODEL_NAME
  annotations:
    opendatahub.io/apiProtocol: REST
    opendatahub.io/recommended-accelerators: '["nvidia.com/gpu"]'
    opendatahub.io/template-display-name: vLLM NVIDIA GPU ServingRuntime
  labels:
    opendatahub.io/dashboard: "true"
spec:
  multiModel: false
  supportedModelFormats:
    - name: vLLM
      autoSelect: true
  containers:
    - name: kserve-container
      # 🟢 EXACT IMAGE FROM YOUR WORKING YAML
      image: registry.redhat.io/rhoai/odh-vllm-cuda-rhel9:v2.25.0-1759340926
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
      # 🟢 CRITICAL: Shared Memory Mount (Was missing in previous attempts)
      volumeMounts:
        - mountPath: /dev/shm
          name: shm
  volumes:
    - name: shm
      emptyDir:
        medium: Memory
        sizeLimit: 2Gi
EOF

# --- 6. DEPLOY INFERENCE SERVICE ---
echo "➤ Deploying InferenceService..."

cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: $MODEL_NAME
  labels:
    opendatahub.io/dashboard: "true"
    networking.kserve.io/visibility: exposed
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  predictor:
    serviceAccountName: $SERVICE_ACCOUNT
    model:
      modelFormat:
        name: vLLM
      
      # Points to the local runtime we defined above (Same name as model)
      runtime: $MODEL_NAME
      
      # 🛠️ STORAGE: We swap OCI:// for your MinIO Secret 🛠️
      storage:
        key: $SECRET_NAME
        path: $MODEL_PATH
      
      args:
        - "--dtype=float16"
        - "--max-model-len=2000" 
      
      resources:
        requests:
          cpu: "2"
          memory: "2Gi"
          nvidia.com/gpu: "1"
        limits:
          cpu: "4"
          memory: "8Gi"
          nvidia.com/gpu: "1"
    tolerations:
      - effect: NoSchedule
        key: nvidia.com/gpu
        operator: Exists
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