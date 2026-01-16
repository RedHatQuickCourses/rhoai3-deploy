# Deployment Validation Report

## Overview
This document validates the deployment scripts against the lab instructions in `model-serving.adoc` and identifies variable mismatches and errors.

---

## Variable Inventory

### Core Configuration Variables

| Variable | Expected Value | Used In | Status |
|----------|---------------|---------|--------|
| `NAMESPACE` | `rhoai-model-vllm-lab` | All scripts | ✅ Consistent |
| `MODEL_NAME` | `granite-4.0-micro` | `deploy-serve.sh`, lab | ✅ Consistent |
| `MODEL_PATH` | `ibm-granite/granite-4.0-micro` | `deploy-serve.sh`, `fast-track.sh` | ✅ Consistent |
| `MODEL_ID` | `ibm-granite/granite-4.0-micro` | `fast-track.sh` | ✅ Consistent |
| `CONTEXT_LIMIT` | `16000` | `deploy-serve.sh`, lab | ✅ Consistent |
| `DATA_CONNECTION` | `aws-connection-minio` | `deploy-serve.sh`, `fast-track.sh` | ✅ Consistent |
| `S3_BUCKET` | `models-secure` | `fast-track.sh` | ✅ Consistent |
| `MINIO_ACCESS_KEY` | `minio` | `fast-track.sh`, `minio-backend.yaml`, `s3ui-deployment.yaml` | ✅ Consistent |
| `MINIO_SECRET_KEY` | `minio123` | `fast-track.sh`, `minio-backend.yaml`, `s3ui-deployment.yaml` | ✅ Consistent |

---

## Critical Issues Found

### 1. ❌ Script Name Mismatch
**Location:** `modules/chapter1/pages/model-serving.adoc` (lines 50, 63, 77-78)

**Issue:** The lab references `deploy/serve_model.sh` but the actual file is `deploy/deploy-serve.sh`

**Impact:** Users will get "file not found" errors when following the lab instructions.

**References:**
- Line 50: `Our script (deploy/serve_model.sh)`
- Line 63: `.Key Configuration Block (deploy/serve_model.sh)`
- Line 77-78: `chmod +x deploy/serve_model.sh` and `./deploy/serve_model.sh`

**Fix Required:** Update all references in `model-serving.adoc` to use `deploy/deploy-serve.sh`

---

### 2. ❌ Model Name Inconsistency in Validation Step
**Location:** `modules/chapter1/pages/model-serving.adoc` (line 96)

**Issue:** The pod label check uses `granite-4b-server` but the actual model name is `granite-4.0-micro`

**Current Code:**
```bash
oc get pod -l serving.kserve.io/inferenceservice=granite-4b-server \
  -n rhoai-model-vllm-lab \
  -o jsonpath='{.items[0].spec.containers[0].args}'
```

**Expected:** Should use `granite-4.0-micro` to match the `MODEL_NAME` variable.

**Impact:** The validation command will fail to find the pod.

**Fix Required:** Change `granite-4b-server` to `granite-4.0-micro` in line 96.

---

### 3. ❌ Namespace Mismatch in S3UI Deployment
**Location:** `deploy/infrastructure/minio/s3ui-deployment.yaml` (line 42)

**Issue:** The S3UI deployment references the wrong namespace in the MinIO endpoint URL.

**Current Code:**
```yaml
- name: S3_ENDPOINT_URL
  value: "http://minio-service.rhoai-model-registry-lab.svc.cluster.local:9000"
```

**Expected:** Should use `rhoai-model-vllm-lab` to match the actual namespace.

**Impact:** S3UI will not be able to connect to MinIO if deployed in the correct namespace.

**Fix Required:** Change `rhoai-model-registry-lab` to `rhoai-model-vllm-lab` in line 42.

---

### 4. ⚠️ Fast-Track Script Name Inconsistency
**Location:** Multiple files reference `fast_track_serving.sh` but the actual file is `fast-track.sh`

**Files Affected:**
- `modules/chapter1/pages/fast-track.adoc` (lines 31-32)
- `README.md` (lines 25-26, 107)

**Impact:** Users following documentation will get "file not found" errors.

**Fix Required:** Update references to use `deploy/fast-track.sh` OR rename the file to match documentation.

---

### 5. ⚠️ README.md Contains Outdated Information
**Location:** `README.md` (multiple lines)

**Issues:**
- Line 43: References `granite-2b-server` instead of `granite-4.0-micro`
- Line 43: References namespace `rhoai-model-registry-lab` instead of `rhoai-model-vllm-lab`
- Line 49: References model name `granite-2b-server` instead of `granite-4.0-micro`
- Line 137: References `granite-2b-server` in troubleshooting section

**Impact:** Users following the README will use incorrect commands.

**Fix Required:** Update all model names and namespaces in README.md to match current configuration.

---

## Variable Flow Validation

### Deployment Flow: Fast-Track → Model Serving

1. **Fast-Track Script (`deploy/fast-track.sh`):**
   - Creates namespace: `rhoai-model-vllm-lab` ✅
   - Deploys MinIO with credentials: `minio` / `minio123` ✅
   - Creates data connection: `aws-connection-minio` ✅
   - Downloads model: `ibm-granite/granite-4.0-micro` ✅
   - Uploads to bucket: `models-secure` ✅
   - Model path in S3: `ibm-granite/granite-4.0-micro` ✅

2. **Deploy-Serve Script (`deploy/deploy-serve.sh`):**
   - Uses namespace: `rhoai-model-vllm-lab` ✅
   - Uses data connection: `aws-connection-minio` ✅
   - Uses model path: `ibm-granite/granite-4.0-micro` ✅
   - Sets context limit: `16000` ✅
   - Creates InferenceService: `granite-4.0-micro` ✅

**Result:** ✅ Variable flow is consistent between scripts (except for issues #2 and #3 above).

---

## Validation Commands Check

### Command 1: Pod Arguments Check
**Location:** `model-serving.adoc` line 96

**Current:**
```bash
oc get pod -l serving.kserve.io/inferenceservice=granite-4b-server \
  -n rhoai-model-vllm-lab \
  -o jsonpath='{.items[0].spec.containers[0].args}'
```

**Issue:** Label selector uses `granite-4b-server` but should be `granite-4.0-micro`

**Corrected:**
```bash
oc get pod -l serving.kserve.io/inferenceservice=granite-4.0-micro \
  -n rhoai-model-vllm-lab \
  -o jsonpath='{.items[0].spec.containers[0].args}'
```

### Command 2: API Test
**Location:** `model-serving.adoc` lines 108-117

**Status:** ✅ Correct - Uses `granite-4.0-micro` and correct namespace.

---

## Summary

### ✅ What Works
- All core variables are consistent across deployment scripts
- Model paths and names match between fast-track and deploy-serve
- Namespace is consistent in main scripts
- MinIO credentials are consistent
- Data connection name is consistent

### ❌ Critical Fixes Needed
1. Fix script name reference: `serve_model.sh` → `deploy-serve.sh`
2. Fix pod label in validation: `granite-4b-server` → `granite-4.0-micro`
3. Fix S3UI namespace: `rhoai-model-registry-lab` → `rhoai-model-vllm-lab`

### ⚠️ Documentation Updates Needed
1. Update fast-track script references
2. Update README.md with correct model names and namespaces

---

## Recommended Action Items

1. **High Priority:**
   - [ ] Update `model-serving.adoc` to reference `deploy/deploy-serve.sh`
   - [ ] Fix pod label selector in `model-serving.adoc` line 96
   - [ ] Fix namespace in `s3ui-deployment.yaml` line 42

2. **Medium Priority:**
   - [ ] Update `fast-track.adoc` script references
   - [ ] Update `README.md` with correct model names and namespaces

3. **Low Priority:**
   - [ ] Consider standardizing script naming convention (decide on `-` vs `_`)

---

## Date: 2025-01-27
**Validated by:** AI Assistant
**Status:** Issues identified, fixes recommended
