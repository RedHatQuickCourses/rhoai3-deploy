# Intelligent Model Deployment with llm-d
**Maximize GPU ROI Through Intelligent Routing**

> **The Problem:** Standard model deployments waste GPU cycles, recomputing context and routing requests randomly.  
> **The Solution:** Distributed Inference with `llm-d` provides intelligent, cache-aware routing that maximizes GPU utilization and reduces latency.

This repository contains a complete **"Course-in-a-Box"** that teaches you how to deploy models using **Distributed Inference with `llm-d`** on Red Hat OpenShift AI 3.0, enabling intelligent routing and KV cache off-loading for all model deployments.

---

## 📚 Option 1: View the Full Course (Antora)

This repository is structured as an Antora documentation site. To view the full learning experience with diagrams, architecture deep-dives, and troubleshooting guides:

### Using Docker (Recommended)
```bash
docker run -u $(id -u) -v $PWD:/antora:Z --rm -t antora/antora antora-playbook.yml
# Open the generated site:
# open build/site/index.html
```

### Using Local NPM

```bash
npm install
npx antora antora-playbook.yml
# Open build/site/index.html
```

---

## ⚡ Option 2: The Fast Track (Deployment Guide)

If you are an experienced Platform Engineer and just want to deploy a model with `llm-d` **now**, follow these steps.

### Prerequisites

* **Cluster:** OpenShift AI 3.0 installed (OpenShift 4.19+).
* **Access:** `cluster-admin` privileges (required to configure Gateway API).
* **CLI:** `oc` installed locally.
* **Model:** A model ready to deploy (from Hugging Face, private registry, or S3).

### Step 1: Verify Gateway API Support

The Gateway API is required for intelligent routing. OpenShift AI 3.0 includes Gateway API support.

```bash
# Check Gateway API CRDs
oc get crd | grep gateway
```

*Expected Output:* You should see `httproutes.gateway.networking.k8s.io` and related CRDs.

[NOTE]
.If Gateway API is Not Available
====
If you do not see Gateway API CRDs, you may need to install OpenShift Service Mesh or kGateway. Consult your cluster administrator or the OpenShift AI 3.0 documentation.
====

### Step 2: Install LeaderWorkerSet Operator (Multi-Node & MoE Only)

[IMPORTANT]
.When You Need LeaderWorkerSet
====
The LeaderWorkerSet Operator is **only required** for:
* **Multi-node deployments:** When your model requires sharding across multiple nodes.
* **Mixture-of-Experts (MoE) models:** When deploying MoE models with expert parallelism.

For **single-node deployments** (most common), you can **skip this step**.
====

If deploying multi-node or MoE models:

```bash
# Install via OpenShift Console:
# 1. Navigate to Operators → OperatorHub
# 2. Search for "Leader Worker Set"
# 3. Click Install and accept defaults

# Verify installation
oc get csv -n openshift-operators | grep leader-worker-set
```

### Step 3: Create the Project

```bash
oc new-project my-llmd-deployment
```

### Step 4: Deploy Model with llm-d

Create the `LLMInferenceService` YAML file:

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: qwen-model
  namespace: my-llmd-deployment
  annotations:
    opendatahub.io/hardware-profile-name: gpu-profile
    opendatahub.io/hardware-profile-namespace: redhat-ods-applications
    opendatahub.io/model-type: generative
    openshift.io/display-name: Qwen Model
    security.opendatahub.io/enable-auth: 'false'
spec:
  replicas: 1
  model:
    # Model URI - supports Hugging Face, private registry, or S3
    uri: hf://Qwen/Qwen3-0.6B
    name: Qwen/Qwen3-0.6B
  router:
    scheduler:
      template:
        containers:
          - name: main
            env:
              - name: TOKENIZER_CACHE_DIR
                value: /tmp/tokenizer-cache
              - name: HF_HOME
                value: /tmp/tokenizer-cache
              - name: TRANSFORMERS_CACHE
                value: /tmp/tokenizer-cache
              - name: XDG_CACHE_HOME
                value: /tmp
            args:
              - --pool-group
              - inference.networking.x-k8s.io
              - '--pool-name'
              - '{{ ChildName .ObjectMeta.Name `-inference-pool` }}'
              - '--pool-namespace'
              - '{{ .ObjectMeta.Namespace }}'
              - '--zap-encoder'
              - json
              - '--grpc-port'
              - '9002'
              - '--grpc-health-port'
              - '9003'
              - '--secure-serving'
              - '--model-server-metrics-scheme'
              - https
              - '--config-text'
              - |
                apiVersion: inference.networking.x-k8s.io/v1alpha1
                kind: EndpointPickerConfig
                plugins:
                - type: single-profile-handler
                - type: queue-scorer
                - type: kv-cache-utilization-scorer
                - type: prefix-cache-scorer
                schedulingProfiles:
                - name: default
                  plugins:
                  - pluginRef: queue-scorer
                    weight: 2
                  - pluginRef: kv-cache-utilization-scorer
                    weight: 2
                  - pluginRef: prefix-cache-scorer
                    weight: 3
            volumeMounts:
              - name: tokenizer-cache
                mountPath: /tmp/tokenizer-cache
              - name: cachi2-cache
                mountPath: /cachi2
        volumes:
          - name: tokenizer-cache
            emptyDir: {}
          - name: cachi2-cache
            emptyDir: {}
    route: { }
    gateway: { }
  template:
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
    containers:
      - name: main
        env:
          - name: VLLM_ADDITIONAL_ARGS
            value: "--disable-uvicorn-access-log --max-model-len=16000"
        resources:
          limits:
            cpu: '1'
            memory: 8Gi
            nvidia.com/gpu: "1"
          requests:
            cpu: '1'
            memory: 8Gi
            nvidia.com/gpu: "1"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
            scheme: HTTPS
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 30
          failureThreshold: 5
```

Apply the deployment:

```bash
oc apply -f llm-inference-service.yaml
```

Monitor the deployment:

```bash
oc get llminferenceservice -n my-llmd-deployment -w
```

Wait for status to show **Ready** (may take several minutes).

### Step 5: Get the Inference URL

```bash
export INFERENCE_URL=$(oc get gateway openshift-ai-inference -n openshift-ingress -o jsonpath='{.status.addresses[0].value}')
echo "Inference Endpoint: http://$INFERENCE_URL/my-llmd-deployment/qwen-model/v1"
```

### Step 6: Test Intelligent Routing

Send a test request:

```bash
curl -k -X POST "http://$INFERENCE_URL/my-llmd-deployment/qwen-model/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Explain Kubernetes in 50 words."}
    ]
  }'
```

Send the same request again to verify cache hit (should be faster):

```bash
# Run the same command again
# Compare response times - second request should be faster due to cache hit
```

### Step 7: Verify Intelligent Routing

Check the pods to verify intelligent routing components:

```bash
# Check Inference Scheduler
oc get pods -n my-llmd-deployment -l component=inference-scheduler

# Check vLLM Worker Pods
oc get pods -n my-llmd-deployment -l component=vllm-worker

# Check HTTPRoute
oc get httproute -n my-llmd-deployment
```

Monitor metrics in OpenShift Console → **Observe** → **Dashboards**:
* Look for `vllm_llmd_kv_cache_hit_rate` (should be > 0 after multiple requests)
* Monitor `vllm_llmd_time_to_first_token_seconds` (TTFT should be lower for cache hits)

---

## 📂 Repository Structure

```text
/
├── modules/                  # Antora Course Source (Adoc files)
│   └── chapter1/pages/      # The actual learning content
│       ├── index.adoc       # Introduction & Value
│       ├── section1.adoc   # Architecture Deep Dive
│       ├── section2.adoc   # The Deployment Lab
│       └── section3.adoc   # Troubleshooting
│
└── antora-playbook.yml      # Antora Build Configuration
```

## 🛠 Troubleshooting

* **Scheduler Not Routing?** Check `oc logs -n <namespace> -l component=inference-scheduler` for errors.
* **Pods Not Starting?** Verify GPU availability: `oc describe node | grep nvidia.com/gpu`
* **Cache Hits Not Occurring?** Verify scheduler configuration includes `kv-cache-utilization-scorer` plugin.
* **Model Not Loading?** Check model URI format and storage access.

For detailed troubleshooting, see the full course content or `modules/chapter1/pages/section3.adoc`.

---

## 🎯 Key Concepts

### Intelligent Routing
`llm-d` routes requests to pods based on:
* **KV Cache Affinity:** Routes to pods that already hold the conversation context (cache hits).
* **Queue Depth:** Balances load across pods.
* **Prefix Matching:** Routes based on prompt prefix for even more efficient cache reuse.

### KV Cache Off-Loading
The KV Cache stores conversation context in GPU memory. `llm-d` manages this cache intelligently:
* **Cache Hits:** Avoid expensive Prefill computation, reducing latency and cost.
* **Cache Management:** Automatically tracks cache locations and evicts least-recently-used caches.

### Benefits for All Deployments
Whether you deploy from your private registry, the public catalog, or Hugging Face, `llm-d` provides intelligent routing and cache management that maximizes GPU ROI.

---

## 📖 Course Content Overview

This course covers:

1. **Introduction & Value:** Understanding the business value of intelligent model deployment.
2. **Architecture Deep Dive:** Technical architecture of `llm-d`, intelligent routing, and KV cache management.
3. **The Deployment Lab:** Step-by-step guide to deploying models with `llm-d`.
4. **Troubleshooting:** SRE playbook for debugging and optimizing deployments.

---

## 🔗 Related Courses

This course is part of a learning path that includes:
* **Model Registry Course:** Learn to govern and manage AI assets in a private registry.
* **Model Deployment Course (This Course):** Learn to deploy models with intelligent routing.

Each course is standalone but designed to work together as a complete AI Factory curriculum.
