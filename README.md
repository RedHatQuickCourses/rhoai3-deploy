
# Enterprise Model Serving with OpenShift AI
**From "Shadow AI" to Governed, Tuned, and Automated Inference**

> **The Problem:** Deploying LLMs is not like deploying microservices. Default configurations lead to Out-Of-Memory (OOM) crashes, wasted GPU funds, and unpredictable latency.  
> **The Solution:** A structured engineering approach to **Selection**, **Sizing**, **Tuning**, and **Automation** using vLLM and Red Hat OpenShift AI.

This repository contains the complete **"Enterprise Serving"** learning path. It guides Platform Engineers from the basics of GPU architecture to a production-ready, GitOps-based deployment of the **IBM Granite-3.3-2B** model.

---

## ⚡ Quick Start: The "Fast Track"

If you are an experienced Engineer and simply want to see the **vLLM Serving Automation** in action (skipping the theory), follow these steps to deploy a tuned Granite model immediately.

### 1. Prerequisites
* **Cluster:** Red Hat OpenShift AI 3.0 installed.
* **Hardware:** At least 1 Node with an NVIDIA GPU (T4, A10G, or L4).
* **CLI:** `oc` logged in with `cluster-admin` privileges.

### 2. Setup the Environment
(Optional) If you do not have an S3 bucket or Data Connection, run this script to deploy MinIO and download the model automatically.

```bash
chmod +x deploy/fast_track_serving.sh
./deploy/fast_track_serving.sh
3. Deploy the Model (GitOps)
Run the automated deployment script. This creates the ServingRuntime (Engine) and InferenceService (Workload) with specific tuning parameters (max-model-len=8192) to prevent crashes.

Bash

chmod +x deploy/serve_model.sh
./deploy/serve_model.sh
4. Verify
Once the script reports ✅ SUCCESS, test the API:

Bash

# Get the URL
export URL=$(oc get inferenceservice granite-2b-server -n rhoai-model-registry-lab -o jsonpath='{.status.url}')

# Test Inference
curl -k $URL/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{ "model": "granite-2b-server", "prompt": "Define MLOps.", "max_tokens": 50 }'
📚 The Full Course (Antora)
This repository is structured as a self-paced course. To view the full learning experience—including GPU sizing math, architecture diagrams, and vLLM deep-dives—build the documentation site.

Using Docker (Recommended)
Bash

docker run -u $(id -u) -v $PWD:/antora:Z --rm -t antora/antora antora-playbook.yml
# Open the generated site:
# open build/site/index.html
Using Local NPM
Bash

npm install
npx antora antora-playbook.yml
📖 Course Modules
Module 1: Strategy & Selection
The Enterprise Reality: Moving beyond leaderboard hype.

Validated Patterns: Using the Red Hat AI Validated Model Repository to de-risk deployment.

Model Selection: Why we chose Granite-3.3-2B (Apache 2.0, Transparent, Efficient).

Module 2: Hardware Architecture & Sizing
GPU Generations: When to use Ampere (A10G) vs. Hopper (H100).

The Math: How to calculate VRAM requirements using the formula:

Total VRAM = (Model Weights * 1.2) + KV Cache.

The Trap: Why a model fits when idle but crashes under load.

Module 3: The Engine (vLLM)
Concepts: Understanding PagedAttention and efficient memory management.

Tuning Guide:

--max-model-len: The "Safety Valve" for context windows.

--gpu-memory-utilization: Optimizing for throughput.

--tensor-parallel-size: Sharding large models across GPUs.

Module 4: Automated Deployment
Infrastructure-as-Code: Abandoning "Click-Ops" for reproducible scripts.

The Lab: Executing serve_model.sh to deploy the tuned stack.

📂 Repository Structure
Plaintext

/
├── deploy/                   # Automation Scripts
│   ├── fast_track_serving.sh # Lab Setup (MinIO + Model Download)
│   └── serve_model.sh        # The Deployment Logic (vLLM + KServe)
│
├── docs/                     # Course Content (AsciiDoc)
│   └── modules/ROOT/pages/
│       ├── index.adoc        # Introduction
│       ├── hardware-sizing.adoc
│       ├── vllm-tuning.adoc
│       └── automated-deployment.adoc
│
└── antora-playbook.yml       # Documentation Build Config
🛠 Troubleshooting
OOMKilled (Exit Code 137):

Cause: The model + KV Cache exceeded GPU VRAM.

Fix: Edit deploy/serve_model.sh and lower CONTEXT_LIMIT (e.g., from 8192 to 4096).

Pod Stuck in Pending:

Cause: No GPU nodes available or quotas exceeded.

Fix: Check oc describe pod <pod-name> for scheduling errors.

Timeout Waiting for Model:

Cause: Downloading the model/image took longer than the script's loop.

Fix: Check logs: oc logs -f -l serving.kserve.io/inferenceservice=granite-2b-server -c kserve-container.

🔗 Next Steps
Once you have mastered single-model serving, you are ready for the advanced modules (Coming Soon):

Quantization Lab: Compressing Granite to INT8 using InstructLab.

Distributed Inference: Using llm-d for intelligent routing across multiple replicas.