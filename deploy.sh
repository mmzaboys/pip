#!/bin/bash
set -e

# ================= Configuration =================
ASG_NAME="staging-agent-asg-2025121613551604090000000a"
REGION="us-east-2"
APP_DIR="/opt/agent"
USER="ubuntu"
GIT_REPO="https://github.com/livekit-examples/agent-starter-react.git"

# Validate environment variables
echo "🔍 Validating environment variables..."
REQUIRED_VARS=("LIVEKIT_API_KEY" "LIVEKIT_API_SECRET" "LIVEKIT_URL")
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
        echo "❌ ERROR: $var is not set"
        exit 1
    fi
    echo "  ✅ $var is set"
done

echo "🔍 Fetching running instances in ASG '$ASG_NAME'..."
INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG_NAME" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text \
    --region "$REGION")

if [[ -z "$INSTANCE_IDS" ]]; then
    echo "❌ No running instances found in ASG!"
    exit 1
fi

echo "✅ Instances found: $INSTANCE_IDS"

# First, test if git and npm are available
echo "🔧 Testing basic dependencies..."
TEST_CMD_ID=$(aws ssm send-command \
    --instance-ids $INSTANCE_IDS \
    --document-name "AWS-RunShellScript" \
    --comment "Test dependencies" \
    --parameters "commands=[
        \"echo 'Testing dependencies...'\",
        \"which git || echo 'git not found'\",
        \"which node || echo 'node not found'\",
        \"which npm || echo 'npm not found'\",
        \"node --version\",
        \"npm --version\",
        \"git --version\",
        \"whoami\",
        \"pwd\"
    ]" \
    --query "Command.CommandId" \
    --output text \
    --region "$REGION")

echo "📄 Test Command ID: $TEST_CMD_ID"
sleep 10

# Check test results
for INSTANCE_ID in $INSTANCE_IDS; do
    echo "--------------------------------------------"
    echo "🔍 Test results for: $INSTANCE_ID"
    echo "--------------------------------------------"
    
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
    echo "Output:"
    echo "$OUTPUT"
    if [[ -n "$ERROR" && "$ERROR" != "Failed to get error" ]]; then
        echo "Errors:"
        echo "$ERROR"
    fi
done

echo "🚀 Sending deployment command via SSM..."
COMMAND_ID=$(aws ssm send-command \
    --instance-ids $INSTANCE_IDS \
    --document-name "AWS-RunShellScript" \
    --comment "Deploy LiveKit agent" \
    --parameters "commands=[
        \"set -e\",
        \"echo '=== Starting deployment ==='\",
        \"echo '1. Updating system...'\",
        \"apt-get update\",
        \"\",
        \"echo '2. Installing dependencies...'\",
        \"apt-get install -y git curl\",
        \"\",
        \"echo '3. Installing Node.js...'\",
        \"curl -fsSL https://deb.nodesource.com/setup_18.x | bash -\",
        \"apt-get install -y nodejs\",
        \"\",
        \"echo '4. Cleaning app directory...'\",
        \"rm -rf '$APP_DIR'/* 2>/dev/null || true\",
        \"mkdir -p '$APP_DIR'\",
        \"cd '$APP_DIR'\",
        \"\",
        \"echo '5. Cloning repository...'\",
        \"git clone '$GIT_REPO' .\",
        \"rm -rf .git\",
        \"\",
        \"echo '6. Creating environment file...'\",
        \"cat > .env.local <<'EOF'\",
        \"LIVEKIT_API_KEY=$LIVEKIT_API_KEY\",
        \"LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET\",
        \"LIVEKIT_URL=$LIVEKIT_URL\",
        \"EOF\",
        \"chmod 600 .env.local\",
        \"\",
        \"echo '7. Installing pnpm...'\",
        \"npm install -g pnpm\",
        \"\",
        \"echo '8. Installing project dependencies...'\",
        \"pnpm install\",
        \"\",
        \"echo '9. Stopping any existing process...'\",
        \"pkill -f 'pnpm dev' 2>/dev/null || true\",
        \"\",
        \"echo '10. Starting agent...'\",
        \"nohup pnpm dev > /var/log/agent.log 2>&1 &\",
        \"AGENT_PID=\\\$!\",
        \"\",
        \"echo '11. Verifying deployment...'\",
        \"sleep 3\",
        \"if ps -p \\\$AGENT_PID > /dev/null; then\",
        \"    echo '✅ Deployment successful!'\",
        \"    echo '   PID: \\\$AGENT_PID'\",
        \"    echo '   Logs: /var/log/agent.log'\",
        \"    echo '   Directory: $APP_DIR'\",
        \"else\",
        \"    echo '❌ Agent failed to start'\",
        \"    echo '   Last 20 lines of log:'\",
        \"    tail -20 /var/log/agent.log 2>/dev/null || echo 'No log file'\",
        \"    exit 1\",
        \"fi\"
    ]" \
    --query "Command.CommandId" \
    --output text \
    --region "$REGION")

echo "📄 Deployment Command ID: $COMMAND_ID"
echo "⏳ Waiting for command to complete (this may take a few minutes)..."

# ================= Wait and fetch logs =================
for INSTANCE_ID in $INSTANCE_IDS; do
    echo "--------------------------------------------"
    echo "🔍 Deployment result for: $INSTANCE_ID"
    echo "--------------------------------------------"
    
    # Wait with timeout
    timeout=300  # 5 minutes
    end_time=$((SECONDS + timeout))
    
    while [ $SECONDS -lt $end_time ]; do
        STATUS=$(aws ssm get-command-invocation \
            --command-id "$COMMAND_ID" \
            --instance-id "$INSTANCE_ID" \
            --query "Status" \
            --output text \
            --region "$REGION" 2>/dev/null || echo "Unknown")
        
        if [[ "$STATUS" == "Success" || "$STATUS" == "Failed" || "$STATUS" == "Cancelled" ]]; then
            break
        fi
        echo "  Status: $STATUS (waiting...)"
        sleep 10
    done
    
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
    
    echo "Final Status: $STATUS"
    echo ""
    echo "📤 Output:"
    echo "$OUTPUT"
    echo ""
    
    if [[ -n "$ERROR" && "$ERROR" != "Failed to get error" ]]; then
        echo "❌ Errors:"
        echo "$ERROR"
    fi
    
    if [[ "$STATUS" == "Failed" ]]; then
        echo ""
        echo "🔧 Debugging failed deployment..."
        DEBUG_CMD_ID=$(aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --comment "Debug failed deployment" \
            --parameters "commands=[
                \"echo '=== Debug Info ==='\",
                \"ls -la '$APP_DIR' 2>/dev/null || echo 'Directory not found'\",
                \"cat '$APP_DIR/.env.local' 2>/dev/null | head -2 || echo 'No env file'\",
                \"tail -50 /var/log/agent.log 2>/dev/null || echo 'No log file'\",
                \"ps aux | grep -E '(node|pnpm)' | grep -v grep || echo 'No processes running'\",
                \"node --version\",
                \"pnpm --version || echo 'pnpm not installed'\"
            ]" \
            --query "Command.CommandId" \
            --output text \
            --region "$REGION")
        
        sleep 5
        DEBUG_OUTPUT=$(aws ssm get-command-invocation \
            --command-id "$DEBUG_CMD_ID" \
            --instance-id "$INSTANCE_ID" \
            --query "StandardOutputContent" \
            --output text \
            --region "$REGION" 2>/dev/null || echo "Debug failed")
        
        echo "🔍 Debug output:"
        echo "$DEBUG_OUTPUT"
    fi
done

echo "🎉 Deployment process completed!"