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

echo "🚀 Simple deployment..."
CMD_ID=$(aws ssm send-command \
    --instance-ids $INSTANCE_IDS \
    --document-name "AWS-RunShellScript" \
    --comment "Simple agent deploy" \
    --timeout-seconds 300 \
    --parameters "commands=[
        \"# Stop existing\",
        \"pkill -f 'pnpm dev' 2>/dev/null || true\",
        \"\",
        \"# Setup\",
        \"rm -rf '$APP_DIR'/* 2>/dev/null || true\",
        \"mkdir -p '$APP_DIR'\",
        \"cd '$APP_DIR'\",
        \"\",
        \"# Clone\",
        \"git clone '$GIT_REPO' .\",
        \"rm -rf .git\",
        \"\",
        \"# Env\",
        \"cat > .env.local <<EOF\",
        \"LIVEKIT_API_KEY=$LIVEKIT_API_KEY\",
        \"LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET\",
        \"LIVEKIT_URL=$LIVEKIT_URL\",
        \"EOF\",
        \"\",
        \"# Install (skip if already done)\",
        \"if [ ! -d node_modules ]; then\",
        \"    pnpm install\",
        \"fi\",
        \"\",
        \"# Start\",
        \"nohup pnpm dev > agent.log 2>&1 &\",
        \"echo '✅ Agent started on port 3000'\",
        \"echo 'Check: tail -f agent.log'\"
    ]" \
    --query "Command.CommandId" \
    --output text \
    --region "$REGION")

echo "📄 Command ID: $CMD_ID"
echo "⏳ Wait 60 seconds for install..."
sleep 60

for INSTANCE_ID in $INSTANCE_IDS; do
    echo ""
    echo "--- $INSTANCE_ID ---"
    
    # Quick check
    CHECK_ID=$(aws ssm send-command \
        --instance-ids $INSTANCE_ID \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"ps aux | grep -E '(node|pnpm)' | grep -v grep | wc -l\"]" \
        --query "Command.CommandId" \
        --output text \
        --region "$REGION")
    
    sleep 3
    PROCESS_COUNT=$(aws ssm get-command-invocation \
        --command-id "$CHECK_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "StandardOutputContent" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "0")
    
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "No IP")
    
    echo "Processes: $PROCESS_COUNT"
    echo "Access: http://$PUBLIC_IP:3000"
done

echo ""
echo "🎉 Done! Try accessing the agent URLs above."