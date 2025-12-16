#!/bin/bash
set -e

ASG_NAME="staging-agent-asg-2025121613551604090000000a"
REGION="us-east-2"
APP_DIR="/opt/agent"
GIT_REPO="https://github.com/livekit-examples/agent-starter-react.git"

# Validate
for var in LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL; do
    [[ -z "${!var}" ]] && { echo "❌ $var not set"; exit 1; }
done

echo "🔍 Fetching instances..."
INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG_NAME" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text \
    --region "$REGION")

[[ -z "$INSTANCE_IDS" ]] && { echo "❌ No instances"; exit 1; }
echo "✅ Instances: $INSTANCE_IDS"

echo "🚀 Deploying..."
COMMAND_ID=$(aws ssm send-command \
    --instance-ids $INSTANCE_IDS \
    --document-name "AWS-RunShellScript" \
    --comment "Deploy LiveKit agent" \
    --timeout-seconds 600 \
    --parameters "commands=[
        \"set -e\",
        \"echo '1. Installing Node.js 18.x...'\",
        \"curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -\",
        \"sudo apt-get install -y nodejs\",
        \"\",
        \"echo '2. Setting up app directory...'\",
        \"sudo mkdir -p '$APP_DIR'\",
        \"sudo chown -R ubuntu:ubuntu '$APP_DIR'\",
        \"cd '$APP_DIR'\",
        \"\",
        \"echo '3. Cloning repo...'\",
        \"sudo rm -rf * .[^.]* 2>/dev/null || true\",
        \"git clone '$GIT_REPO' .\",
        \"sudo rm -rf .git\",
        \"\",
        \"echo '4. Creating env file...'\",
        \"cat > .env.local <<EOF\",
        \"LIVEKIT_API_KEY=$LIVEKIT_API_KEY\",
        \"LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET\",
        \"LIVEKIT_URL=$LIVEKIT_URL\",
        \"EOF\",
        \"\",
        \"echo '5. Installing pnpm and dependencies...'\",
        \"sudo npm install -g pnpm\",
        \"pnpm install\",
        \"\",
        \"echo '6. Starting agent...'\",
        \"pkill -f 'pnpm dev' 2>/dev/null || true\",
        \"nohup pnpm dev > /var/log/agent.log 2>&1 &\",
        \"\",
        \"echo '✅ Deployment done!'\",
        \"echo 'Check: tail -f /var/log/agent.log'\" 
    ]" \
    --query "Command.CommandId" \
    --output text \
    --region "$REGION")

echo "📄 Command ID: $COMMAND_ID"
echo "⏳ Waiting 60 seconds..."
sleep 60

for INSTANCE_ID in $INSTANCE_IDS; do
    echo "--- $INSTANCE_ID ---"
    
    OUTPUT=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "StandardOutputContent" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "No output")
    
    ERROR=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "StandardErrorContent" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "No error")
    
    STATUS=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "Status" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "Unknown")
    
    echo "Status: $STATUS"
    echo "Output:"
    echo "$OUTPUT"
    [[ -n "$ERROR" && "$ERROR" != "No error" ]] && echo "Error: $ERROR"
done

echo "🎉 Done!"