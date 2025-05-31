#!/bin/bash

# Script to generate curl commands for testing the Devgentic agent backend.

# --- Configuration ---
# Default agent URL. The /agent/chat endpoint is used.
# Update this if your agent runs on a different host or port.
AGENT_BASE_URL="http://localhost:8000"
CHAT_ENDPOINT="${AGENT_BASE_URL}/agent/chat"

# --- Helper Function to Make Request ---
# This function takes a JSON payload as an argument and sends it.
# However, for this script, we'll primarily focus on printing the curl commands.
# function send_request() {
#   local payload="$1"
#   echo "Sending request with payload:"
#   echo "$payload"
#   curl -X POST \
#     -H "Content-Type: application/json" \
#     -d "$payload" \
#     "$CHAT_ENDPOINT"
#   echo -e "\n--- End of Request ---\n"
# }

echo "--------------------------------------------------------------------"
echo "Devgentic Agent Test Script - Curl Command Generator"
echo "--------------------------------------------------------------------"
echo "Agent Chat Endpoint: $CHAT_ENDPOINT"
echo "Modify AGENT_BASE_URL in this script if your agent runs elsewhere."
echo "Copy and paste the generated curl commands into your terminal to test."
echo -e "--------------------------------------------------------------------\n"


# --- Test Case 1: New Conversation, Simple Prompt, No Model Change ---
echo "Test Case 1: New Conversation, Simple Prompt"
JSON_PAYLOAD_1=$(cat <<EOF
{
    "conversationId": "conv_new_123",
    "messageContent": {
        "prompt": "Hello agent, what can you do?",
        "files": []
    },
    "agentConfig": [
        {
            "ollama_url": "http://localhost:11434",
            "model": "gemma:2b",
            "tools": ["search"]
        }
    ],
    "metadata": {
        "modelChanged": false
    }
}
EOF
)
# Escape single quotes within the JSON payload for the -d argument of curl
ESCAPED_JSON_PAYLOAD_1=$(echo "$JSON_PAYLOAD_1" | sed "s/'/'\\\\''/g")

echo "Curl command for Test Case 1:"
echo "curl -X POST \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -d '${ESCAPED_JSON_PAYLOAD_1}' \\"
echo "  \"${CHAT_ENDPOINT}\""
echo -e "\n--------------------------------------------------------------------\n"


# --- Test Case 2: Existing Conversation, Prompt with Files, No Model Change ---
echo "Test Case 2: Existing Conversation, Prompt with Files"
JSON_PAYLOAD_2=$(cat <<EOF
{
    "conversationId": "conv_existing_456",
    "messageContent": {
        "prompt": "Can you analyze the sentiment of the text in 'review.txt' and summarize 'report.docx'?",
        "files": ["review.txt", "report.docx", "project/src/main.py"]
    },
    "agentConfig": [
        {
            "ollama_url": "http://localhost:11434",
            "model": "gemma:2b",
            "tools": ["file_reader", "sentiment_analyzer"]
        }
    ],
    "metadata": {
        "modelChanged": false
    }
}
EOF
)
ESCAPED_JSON_PAYLOAD_2=$(echo "$JSON_PAYLOAD_2" | sed "s/'/'\\\\''/g")

echo "Curl command for Test Case 2:"
echo "curl -X POST \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -d '${ESCAPED_JSON_PAYLOAD_2}' \\"
echo "  \"${CHAT_ENDPOINT}\""
echo -e "\n--------------------------------------------------------------------\n"


# --- Test Case 3: Model Change Requested ---
echo "Test Case 3: Requesting a Model Change"
JSON_PAYLOAD_3=$(cat <<EOF
{
    "conversationId": "conv_model_change_789",
    "messageContent": {
        "prompt": "Now, let's try a different approach. What are the key differences between Python and Golang for web development?",
        "files": []
    },
    "agentConfig": [
        {
            "ollama_url": "http://localhost:11434",
            "model": "mistral",
            "tools": ["web_search", "code_interpreter"]
        }
    ],
    "metadata": {
        "modelChanged": true
    }
}
EOF
)
ESCAPED_JSON_PAYLOAD_3=$(echo "$JSON_PAYLOAD_3" | sed "s/'/'\\\\''/g")

echo "Curl command for Test Case 3:"
echo "curl -X POST \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -d '${ESCAPED_JSON_PAYLOAD_3}' \\"
echo "  \"${CHAT_ENDPOINT}\""
echo -e "\n--------------------------------------------------------------------\n"

# --- Test Case 4: Invalid Payload - Empty conversationId (should be caught by Pydantic) ---
# Note: Pydantic should reject this before it hits your custom validator if type is str and not Optional.
# If it's caught by your custom validator, the error message will be from there.
echo "Test Case 4: Invalid Payload - Empty conversationId"
JSON_PAYLOAD_4=$(cat <<EOF
{
    "conversationId": "",
    "messageContent": {
        "prompt": "This should fail.",
        "files": []
    },
    "agentConfig": [
        {
            "ollama_url": "http://localhost:11434",
            "model": "gemma:2b",
            "tools": []
        }
    ],
    "metadata": {
        "modelChanged": false
    }
}
EOF
)
ESCAPED_JSON_PAYLOAD_4=$(echo "$JSON_PAYLOAD_4" | sed "s/'/'\\\\''/g")
echo "Curl command for Test Case 4 (expecting 4xx error):"
echo "curl -X POST \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -d '${ESCAPED_JSON_PAYLOAD_4}' \\"
echo "  \"${CHAT_ENDPOINT}\""
echo -e "\n--------------------------------------------------------------------\n"


# --- Test Case 5: Invalid Payload - Empty agentConfig list (should be caught by Pydantic validator) ---
echo "Test Case 5: Invalid Payload - Empty agentConfig"
JSON_PAYLOAD_5=$(cat <<EOF
{
    "conversationId": "conv_valid_101",
    "messageContent": {
        "prompt": "This should also fail.",
        "files": []
    },
    "agentConfig": [],
    "metadata": {
        "modelChanged": false
    }
}
EOF
)
ESCAPED_JSON_PAYLOAD_5=$(echo "$JSON_PAYLOAD_5" | sed "s/'/'\\\\''/g")
echo "Curl command for Test Case 5 (expecting 4xx error):"
echo "curl -X POST \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -d '${ESCAPED_JSON_PAYLOAD_5}' \\"
echo "  \"${CHAT_ENDPOINT}\""
echo -e "\n--------------------------------------------------------------------\n"

echo "To run a test, copy the entire 'curl ...' command block and paste it into your terminal."
echo "Ensure your Devgentic agent is running and accessible at ${AGENT_BASE_URL}."
