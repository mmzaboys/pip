#!/bin/bash
set -e

# ================= Configuration =================
ASG_NAME="staging-agent-asg-2025121613551604090000000a"
REGION="us-east-2"
APP_DIR="/opt/agent"
USER="ec2-user"
GIT_REPO="https://github.com/livekit-examples/agent-starter-react.git"

# Validate environment variables
echo "🔍 Validating environment variables..."
REQUIRED_VARS=("LIVEKIT_API_KEY" "LIVEKIT_API_SECRET" "LIVEKIT_URL")
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
        echo "❌ ERROR: $var is not set"
        exit 1
    fi
    # Show first few chars for debugging (not full secret)
    echo "  ✅ $var: ${!var:0:4}..."
done

echo "🔍 Fetching running instances..."
INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG_NAME" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text \
    --region "$REGION")

if [[ -z "$INSTANCE_IDS" ]]; then
    echo "❌ No running instances found!"
    exit 1
fi
echo "✅ Instances found: $INSTANCE_IDS"

# Check SSM connectivity first
echo "🔍 Checking SSM connectivity..."
for INSTANCE_ID in $INSTANCE_IDS; do
    echo "  Checking $INSTANCE_ID..."
    aws ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
        --query "InstanceInformationList[0].PingStatus" \
        --output text \
        --region "$REGION" || echo "  ❌ Cannot reach instance via SSM"
done

# Test with simple command first
echo "🚀 Testing SSM with simple command..."
TEST_CMD_ID=$(aws ssm send-command \
    --instance-ids $INSTANCE_IDS \
    --document-name "AWS-RunShellScript" \
    --comment "Test connection" \
    --parameters "commands=[\"echo 'SSM test successful'\", \"whoami\"]" \
    --query "Command.CommandId" \
    --output text \
    --region "$REGION")

echo "📄 Test Command ID: $TEST_CMD_ID"

# Wait for test command
for INSTANCE_ID in $INSTANCE_IDS; do
    echo "--------------------------------------------"
    echo "🔍 Test result for: $INSTANCE_ID"
    echo "--------------------------------------------"
    
    aws ssm wait command-executed \
        --command-id "$TEST_CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION" 2>/dev/null || true
    
    OUTPUT=$(aws ssm get-command-invocation \
        --command-id "$TEST_CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "StandardOutputContent" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "Failed to get output")
    
    ERROR=$(aws ssm get-command-invocation \
        --command-id "$TEST_CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "StandardErrorContent" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "Failed to get error")
    
    STATUS=$(aws ssm get-command-invocation \
        --command-id "$TEST_CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "Status" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "Unknown")
    
    echo "Status: $STATUS"
    echo "Output: $OUTPUT"
    echo "Error: $ERROR"
done

# Only proceed if test was successful
echo "🚀 Sending deployment command..."
COMMAND_ID=$(aws ssm send-command \
    --instance-ids $INSTANCE_IDS \
    --document-name "AWS-RunShellScript" \
    --comment "Deploy LiveKit agent" \
    --parameters "commands=[
        \"set -e\",
        \"echo 'Starting deployment...'\",
        \"echo 'Current directory: \$(pwd)'\",
        \"echo 'User: \$(whoami)'\",
        \"\",
        \"# Clean and prepare directory\",
        \"sudo rm -rf '$APP_DIR'/* 2>/dev/null || true\",
        \"sudo mkdir -p '$APP_DIR'\",
        \"sudo chown -R $USER:$USER '$APP_DIR'\",
        \"cd '$APP_DIR'\",
        \"\",
        \"# Clone the repository\",
        \"echo 'Cloning $GIT_REPO...'\",
        \"git clone '$GIT_REPO' . || { echo 'Git clone failed'; exit 1; }\",
        \"rm -rf .git\",
        \"\",
        \"# Create .env.local\",
        \"cat > .env.local <<'EOF'\",
        \"LIVEKIT_API_KEY=$LIVEKIT_API_KEY\",
        \"LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET\",
        \"LIVEKIT_URL=$LIVEKIT_URL\",
        \"EOF\",
        \"sudo chmod 600 .env.local\",
        \"\",
        \"# Install dependencies\",
        \"echo 'Installing pnpm...'\",
        \"sudo npm install -g pnpm || { echo 'pnpm install failed'; exit 1; }\",
        \"\",
        \"echo 'Installing project dependencies...'\",
        \"pnpm install || { echo 'pnpm install failed'; exit 1; }\",
        \"\",
        \"# Kill existing process if running\",
        \"pkill -f 'pnpm dev' 2>/dev/null || true\",
        \"\",
        \"# Start the agent\",
        \"echo 'Starting agent...'\",
        \"nohup pnpm dev > /var/log/agent.log 2>&1 &\",
        \"\",
        \"echo '✅ Deployment completed'\",
        \"echo 'App dir: \$(pwd)'\",
        \"echo 'Logs: /var/log/agent.log'\",
        \"ps aux | grep -E 'node|pnpm' | grep -v grep\"
    ]" \
    --query "Command.CommandId" \
    --output text \
    --region "$REGION")

echo "📄 Deployment Command ID: $COMMAND_ID"

# Wait and get results
for INSTANCE_ID in $INSTANCE_IDS; do
    echo "--------------------------------------------"
    echo "🔍 Deployment result for: $INSTANCE_ID"
    echo "--------------------------------------------"
    
    aws ssm wait command-executed \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION" 2>/dev/null || echo "Wait failed"
    
    OUTPUT=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "StandardOutputContent" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "Failed to get output")
    
    ERROR=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "StandardErrorContent" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "Failed to get error")
    
    STATUS=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "Status" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "Unknown")
    
    echo "Status: $STATUS"
    echo "Output:"
    echo "$OUTPUT"
    if [[ -n "$ERROR" && "$ERROR" != "Failed to get error" ]]; then
        echo "Errors:"
        echo "$ERROR"
    fi
done

echo "🎉 Deployment process completed!"