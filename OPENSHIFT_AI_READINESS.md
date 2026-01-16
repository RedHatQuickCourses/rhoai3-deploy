# OpenShift AI Deployment Readiness Checklist

## ✅ What's Ready

1. **Variable Consistency**: All variables are consistent across scripts
2. **Script Names**: All script references match actual filenames
3. **Model Names**: Model names use Kubernetes-compatible format (no dots)
4. **Namespace Consistency**: All references use `rhoai-model-vllm-lab`
5. **MinIO Configuration**: MinIO deployment YAML is properly configured

---

## ⚠️ Potential Issues & Recommendations

### 1. **Namespace Creation Missing in deploy-serve.sh**

**Issue:** `deploy-serve.sh` assumes the namespace exists but doesn't create it.

**Impact:** If users run `deploy-serve.sh` without running `fast-track.sh` first, the deployment will fail.

**Recommendation:** Add namespace check/creation at the start of `deploy-serve.sh`:

```bash
# Check/Create Namespace
if ! oc get project "$NAMESPACE" > /dev/null 2>&1; then
    echo "➤ Creating namespace $NAMESPACE..."
    oc new-project "$NAMESPACE"
else
    echo "✔ Namespace $NAMESPACE exists."
fi
```

---

### 2. **Image Pull Authentication**

**Issue:** The vLLM image `quay.io/modh/vllm:rhoai-2.13` may require authentication or may not be publicly accessible.

**Impact:** Pods may fail to pull the image, resulting in `ImagePullBackOff` errors.

**Recommendations:**
- Verify the image exists and is publicly accessible
- If authentication is required, add image pull secrets to the ServingRuntime
- Consider adding a check/validation step before deployment

**Example fix (if auth needed):**
```yaml
spec:
  imagePullSecrets:
    - name: quay-pull-secret
  containers:
    - name: kserve-container
      image: quay.io/modh/vllm:rhoai-2.13
```

---

### 3. **GPU Node Selector Missing**

**Issue:** No node selector specified to ensure pods run on GPU nodes.

**Impact:** Pods may be scheduled on non-GPU nodes, causing failures.

**Recommendation:** Add node selector to InferenceService:

```yaml
spec:
  predictor:
    nodeSelector:
      nvidia.com/gpu.present: "true"
    resources:
      requests:
        nvidia.com/gpu: "1"
```

---

### 4. **Data Connection Secret Format Validation**

**Issue:** The secret format needs to match OpenShift AI's expected format for data connections.

**Current Format (in fast-track.sh):**
```bash
oc create secret generic aws-connection-minio \
    --from-literal=AWS_ACCESS_KEY_ID="..." \
    --from-literal=AWS_SECRET_ACCESS_KEY="..." \
    --from-literal=AWS_S3_ENDPOINT="..." \
    --from-literal=AWS_DEFAULT_REGION="us-east-1" \
    --from-literal=AWS_S3_BUCKET="models-secure"
```

**Recommendation:** Verify this matches OpenShift AI 3.0's expected format. The label `opendatahub.io/dashboard=true` is already present, which is good.

---

### 5. **Service Account for InferenceService**

**Issue:** No service account specified for the InferenceService.

**Impact:** May need specific permissions for image pulls, storage access, or other operations.

**Recommendation:** Consider adding a service account if required by your OpenShift AI setup:

```yaml
spec:
  predictor:
    serviceAccountName: inference-sa
```

---

### 6. **HuggingFace Model Path Verification**

**Issue:** The model path `ibm-granite/granite-4-micro` needs to be verified.

**Current:** 
- `MODEL_ID="ibm-granite/granite-4-micro"` in fast-track.sh
- `MODEL_PATH="ibm-granite/granite-4-micro"` in deploy-serve.sh

**Recommendation:** 
- Verify the actual HuggingFace repository name (it might still be `granite-4.0-micro` on HuggingFace)
- If the HuggingFace repo uses `granite-4.0-micro`, update `MODEL_ID` in fast-track.sh to match, but keep `MODEL_NAME` as `granite-4-micro` for Kubernetes

---

### 7. **Error Handling & Validation**

**Issue:** Limited validation before deployment.

**Recommendations:**
- Add check for `oc` CLI availability
- Verify user has permissions to create resources
- Check if Data Connection secret exists before deploying InferenceService
- Validate GPU nodes are available

**Example additions:**
```bash
# Check prerequisites
if ! command -v oc &> /dev/null; then
    echo "❌ Error: oc CLI not found. Please install OpenShift CLI."
    exit 1
fi

# Check Data Connection exists
if ! oc get secret $DATA_CONNECTION -n $NAMESPACE > /dev/null 2>&1; then
    echo "❌ Error: Data Connection '$DATA_CONNECTION' not found in namespace '$NAMESPACE'"
    echo "   Run fast-track.sh first to create the data connection."
    exit 1
fi
```

---

### 8. **Resource Quotas**

**Issue:** No check for available resources/quota.

**Impact:** Deployment may fail if namespace has resource quotas that are exhausted.

**Recommendation:** Add a check or informative message:

```bash
# Check resource availability (informative)
echo "📊 Checking resource availability..."
oc describe quota -n $NAMESPACE 2>/dev/null || echo "   No quotas configured"
```

---

### 9. **MinIO Service Name Consistency**

**Issue:** Verify MinIO service name matches across all references.

**Current:**
- `fast-track.sh` uses: `http://minio.$NAMESPACE.svc.cluster.local:9000`
- `s3ui-deployment.yaml` uses: `http://minio-service.rhoai-model-vllm-lab.svc.cluster.local:9000`

**Status:** ✅ The minio-backend.yaml creates a service named `minio-service`, so the s3ui reference is correct. However, fast-track.sh uses `minio` which might be incorrect.

**Recommendation:** Verify the actual service name created by minio-backend.yaml and update fast-track.sh if needed.

---

### 10. **Timeout Duration**

**Issue:** The wait loop in `deploy-serve.sh` waits 30 iterations × 10 seconds = 5 minutes.

**Impact:** Large models may take longer to download and load.

**Recommendation:** Consider making timeout configurable or increasing it:

```bash
TIMEOUT_MINUTES=${TIMEOUT_MINUTES:-10}
MAX_ITERATIONS=$((TIMEOUT_MINUTES * 6))  # 6 iterations per minute
```

---

## 🔍 Pre-Deployment Verification Steps

Before running in OpenShift AI, verify:

1. **OpenShift AI Installation:**
   ```bash
   oc get csv -n redhat-ods-operator | grep opendatahub
   ```

2. **GPU Nodes Available:**
   ```bash
   oc get nodes -l nvidia.com/gpu.present=true
   ```

3. **KServe/RHOAI Operators:**
   ```bash
   oc get crd | grep inferenceservice
   oc get crd | grep servingruntime
   ```

4. **Image Registry Access:**
   ```bash
   oc run test-pull --image=quay.io/modh/vllm:rhoai-2.13 --rm -it --restart=Never --command -- echo "Image pull successful"
   ```

5. **Namespace Permissions:**
   ```bash
   oc auth can-i create inferenceservices -n rhoai-model-vllm-lab
   oc auth can-i create servingruntimes -n rhoai-model-vllm-lab
   ```

---

## 📝 Recommended Script Improvements

### deploy-serve.sh Enhancements:

1. Add namespace creation check
2. Add prerequisite validation (oc CLI, permissions, data connection)
3. Add GPU node availability check
4. Add image pull test
5. Improve error messages
6. Make timeout configurable

### fast-track.sh Enhancements:

1. Verify MinIO service name matches actual deployment
2. Add validation that model download completed successfully
3. Add check for sufficient storage space

---

## 🎯 Priority Fixes

**High Priority:**
1. ✅ Add namespace creation to deploy-serve.sh
2. ✅ Verify MinIO service name consistency
3. ✅ Add data connection existence check

**Medium Priority:**
4. ✅ Add GPU node selector
5. ✅ Verify image pull access
6. ✅ Add prerequisite validation

**Low Priority:**
7. ✅ Improve error messages
8. ✅ Make timeout configurable
9. ✅ Add resource quota checks

---

## Date: 2025-01-27
**Status:** Ready for testing with recommended improvements
