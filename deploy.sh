#!/bin/bash
set -e

ASG_NAME="staging-agent-asg-2025121613551604090000000a"
REGION="us-east-2"
APP_DIR="/opt/agent"
GIT_REPO="https://github.com/livekit-examples/agent-starter-react.git"

# Validate env vars
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

echo "🚀 Deploying..."

aws ssm send-command \
    --instance-ids $INSTANCE_IDS \
    --document-name "AWS-RunShellScript" \
    --comment "Agent deploy (fixed)" \
    --timeout-seconds 600 \
    --parameters "commands=[
        \"set -e\",
        \"echo 'Stopping old app'\",
        \"pkill -f 'pnpm dev' 2>/dev/null || true\",
        \"\",
        \"echo 'Reset app dir'\",
        \"rm -rf '$APP_DIR'\",
        \"mkdir -p '$APP_DIR'\",
        \"cd '$APP_DIR'\",
        \"\",
        \"echo 'Clone repo'\",
        \"git clone '$GIT_REPO' .\",
        \"rm -rf .git\",
        \"\",
        \"echo 'Create env file'\",
        \"cat > .env.local <<EOF\",
        \"LIVEKIT_API_KEY=$LIVEKIT_API_KEY\",
        \"LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET\",
        \"LIVEKIT_URL=$LIVEKIT_URL\",
        \"EOF\",
        \"chmod 600 .env.local\",
        \"\",
        \"echo 'Ensure pnpm'\",
        \"command -v pnpm >/dev/null 2>&1 || npm install -g pnpm\",
        \"\",
        \"echo 'Install deps'\",
        \"pnpm install\",
        \"\",
        \"echo 'Start agent'\",
        \"nohup pnpm dev > agent.log 2>&1 &\",
        \"sleep 3\",
        \"ps aux | grep -E '(node|pnpm)' | grep -v grep\",
        \"echo '✅ Agent running'\"
    ]" \
    --region "$REGION"

echo "⏳ Waiting 20s..."
sleep 20

for INSTANCE_ID in $INSTANCE_IDS; do
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text \
        --region "$REGION")
    echo "🌍 http://$PUBLIC_IP:3000"
done

echo "🎉 Done"
