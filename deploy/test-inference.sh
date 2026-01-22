#!/bin/bash

# ==============================================================================
# AI FACTORY: PERFORMANCE VALIDATION
# Description: Sends a request to the model and calculates Tokens Per Second (TPS).
# ==============================================================================

NAMESPACE="model-deploy-lab"
SERVICE_NAME="granite-4-micro"

# 1. GET THE ROUTE
# dynamically fetch the external URL of the inference service
echo "🔍 Discovring API Route..."
ROUTE=$(oc get inferenceservice $SERVICE_NAME -n $NAMESPACE -o jsonpath='{.status.url}')

if [ -z "$ROUTE" ]; then
    echo "❌ Error: Could not find InferenceService URL. Is it deployed?"
    exit 1
fi

echo "✅ Target: $ROUTE"
echo "------------------------------------------------"

# 2. DEFINE THE PROMPT
# A prompt complex enough to generate a substantial response for measuring speed.
PROMPT="Explain the concept of 'PagedAttention' in vLLM to a 5-year-old using a toybox analogy."

echo "📤 Sending Request..."
echo "   Prompt: '$PROMPT'"

# 3. EXECUTE & TIME THE REQUEST
# We use curl to send the request and capture the total time
start_time=$(date +%s.%N)

RESPONSE=$(curl -k -s -X POST "$ROUTE/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$SERVICE_NAME\",
    \"messages\": [
      {\"role\": \"user\", \"content\": \"$PROMPT\"}
    ],
    \"temperature\": 0.7,
    \"max_tokens\": 256
  }")

end_time=$(date +%s.%N)

# 4. PARSE & CALCULATE METRICS
# Extract the generated text and token counts using grep/sed (to avoid requiring jq)
CONTENT=$(echo "$RESPONSE" | grep -o '"content":"[^"]*"' | sed 's/"content":"//;s/"//')
TOTAL_TOKENS=$(echo "$RESPONSE" | grep -o '"completion_tokens":[0-9]*' | awk -F: '{print $2}')

# Calculate duration
duration=$(echo "$end_time - $start_time" | bc)

# Calculate TPS (Tokens Per Second)
if [ -n "$TOTAL_TOKENS" ] && [ "$TOTAL_TOKENS" -gt 0 ]; then
    tps=$(echo "$TOTAL_TOKENS / $duration" | bc -l)
    formatted_tps=$(printf "%.2f" $tps)
else
    formatted_tps="0"
fi

# 5. THE REPORT CARD
echo "------------------------------------------------"
echo "✅ RESPONSE RECEIVED"
echo "------------------------------------------------"
echo "🤖 Model Output:"
echo -e "$CONTENT"
echo ""
echo "------------------------------------------------"
echo "📊 PERFORMANCE METRICS (The 'Why Build' Proof)"
echo "------------------------------------------------"
echo "⏱️  Latency (Total Time):  $(printf "%.2f" $duration) seconds"
echo "🔢  Tokens Generated:      $TOTAL_TOKENS"
echo "🚀  Throughput (TPS):      $formatted_tps tokens/sec"
echo "------------------------------------------------"

if (( $(echo "$formatted_tps > 50" | bc -l) )); then
    echo "🏆 RESULT: HIGH PERFORMANCE. This factory is optimized."
else
    echo "⚠️  RESULT: STANDARD PERFORMANCE. Consider increasing Batch Size."
fi