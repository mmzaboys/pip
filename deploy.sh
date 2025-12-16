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

# ================= Test SSM =================
echo "🚀 Testing SSM with simple command..."
TEST_CMD_ID=$(aws ssm send-command \
    --instance-ids $INSTANCE_IDS \
    --document-name "AWS-RunShellScript" \
    --comment "Test connection" \
    --parameters "commands=[\"echo 'SSM test successful'\", \"whoami\"]" \
    --query "Command.CommandId" \
    --output text \
    --region "$REGION")

for INSTANCE_ID in $INSTANCE_IDS; do
    aws ssm wait command-executed \
        --command-id "$TEST_CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION" || true
done

# ================= Deployment =================
echo "🚀 Sending deployment command..."
COMMAND_ID=$(aws ssm send-command \
    --instance-ids $INSTANCE_IDS \
    --document-name "AWS-RunShellScript" \
    --comment "Deploy LiveKit agent" \
    --parameters "commands=[
        \"set -e\",
        \"echo 'Starting deployment...'\",
        \"echo 'User: \$(whoami)'\",
        \"\",
        \"# 🔥 FIX: remove directory completely\",
        \"rm -rf '$APP_DIR' 2>/dev/null || true\",
        \"mkdir -p '$APP_DIR'\",
        \"chown -R $USER:$USER '$APP_DIR'\",
        \"cd '$APP_DIR'\",
        \"\",
        \"# Clone repository\",
        \"git clone '$GIT_REPO' .\",
        \"rm -rf .git\",
        \"\",
        \"# Create env file\",
        \"cat > .env.local <<'EOF'\",
        \"LIVEKIT_API_KEY=$LIVEKIT_API_KEY\",
        \"LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET\",
        \"LIVEKIT_URL=$LIVEKIT_URL\",
        \"EOF\",
        \"chmod 600 .env.local\",
        \"\",
        \"# Install pnpm\",
        \"npm install -g pnpm\",
        \"\",
        \"# Install deps\",
        \"pnpm install\",
        \"\",
        \"# Restart app\",
        \"pkill -f 'pnpm dev' 2>/dev/null || true\",
        \"nohup pnpm dev > /var/log/agent.log 2>&1 &\",
        \"\",
        \"echo '✅ Deployment completed'\"
    ]" \
    --query "Command.CommandId" \
    --output text \
    --region "$REGION")

echo "📄 Deployment Command ID: $COMMAND_ID"

for INSTANCE_ID in $INSTANCE_IDS; do
    echo "--------------------------------------------"
    echo "🔍 Result for $INSTANCE_ID"
    echo "--------------------------------------------"
    aws ssm wait command-executed \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION" || true

    aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION"
done

echo "🎉 Deployment process completed!"
