#!/bin/bash
set -e  # Exit on error

# ================= Configuration =================
ASG_NAME="staging-agent-asg-2025121613551604090000000a"
REGION="us-east-2"
APP_DIR="/opt/agent"
USER="ec2-user"
GIT_REPO="https://github.com/livekit-examples/agent-starter-react.git"

# Validate environment variables (from GitHub Secrets)
echo "🔍 Validating environment variables..."
REQUIRED_VARS=("LIVEKIT_API_KEY" "LIVEKIT_API_SECRET" "LIVEKIT_URL")
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
        echo "❌ ERROR: $var is not set"
        echo "Make sure it's set as a GitHub Secret and passed in workflow"
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

echo "🚀 Sending deployment command via SSM..."
COMMAND_ID=$(aws ssm send-command \
    --instance-ids $INSTANCE_IDS \
    --document-name "AWS-RunShellScript" \
    --comment "Deploy LiveKit agent" \
    --parameters "commands=[
        \"set -e\",
        \"# Clean and prepare directory\",
        \"rm -rf '$APP_DIR'/* 2>/dev/null || true\",
        \"mkdir -p '$APP_DIR'\",
        \"cd '$APP_DIR'\",
        \"\",
        \"# Clone the repository\",
        \"echo 'Cloning $GIT_REPO...'\",
        \"git clone '$GIT_REPO' .\",
        \"rm -rf .git\",
        \"\",
        \"# Create .env.local with environment variables\",
        \"cat > .env.local <<'EOF'\",
        \"LIVEKIT_API_KEY=$LIVEKIT_API_KEY\",
        \"LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET\",
        \"LIVEKIT_URL=$LIVEKIT_URL\",
        \"EOF\",
        \"\",
        \"# Secure the environment file\",
        \"chmod 600 .env.local\",
        \"\",
        \"# Set permissions\",
        \"chown -R $USER:$USER '$APP_DIR'\",
        \"chmod -R 755 '$APP_DIR'\",
        \"\",
        \"# Install dependencies and start dev server\",
        \"npm install -g pnpm\",
        \"pnpm install\",
        \"\",
        \"# Start the agent (run in background)\",
        \"nohup pnpm dev > /var/log/agent.log 2>&1 &\",
        \"\",
        \"# Verify deployment\",
        \"echo '✅ Deployment completed successfully'\",
        \"echo 'App directory: $APP_DIR'\",
        \"echo 'Log file: /var/log/agent.log'\"
    ]" \
    --query "Command.CommandId" \
    --output text \
    --region "$REGION")

echo "📄 SSM Command ID: $COMMAND_ID"

# ================= Wait and fetch logs =================
for INSTANCE_ID in $INSTANCE_IDS; do
    echo "--------------------------------------------"
    echo "🔍 Checking instance: $INSTANCE_ID"
    echo "--------------------------------------------"

    aws ssm wait command-executed \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION"

    OUTPUT=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "StandardOutputContent" \
        --output text \
        --region "$REGION")

    ERROR=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "StandardErrorContent" \
        --output text \
        --region "$REGION")

    if [[ -n "$ERROR" ]]; then
        echo "❌ Errors on $INSTANCE_ID:"
        echo "$ERROR"
    fi
    
    echo "📤 Output:"
    echo "$OUTPUT"
done

echo "🎉 Deployment completed on all instances!"