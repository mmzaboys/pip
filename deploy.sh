#!/bin/bash
set -e

# ================= Configuration =================
ASG_NAME="staging-agent-asg-2025121912013180880000000a"
REGION="us-east-2"
APP_DIR="/opt/agent"
GIT_REPO="https://github.com/livekit-examples/agent-starter-react.git"

# Validate environment variables
for var in LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL; do
    if [[ -z "${!var}" ]]; then
        echo "❌ ERROR: $var not set"
        exit 1
    fi
    echo "✅ $var: ${!var:0:4}..."  # Show first few chars for sanity
done

echo "🔍 Fetching running instances in ASG '$ASG_NAME'..."
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

echo "🚀 Deploying agent to all instances..."

aws ssm send-command \
    --instance-ids $INSTANCE_IDS \
    --document-name "AWS-RunShellScript" \
    --comment "Deploy LiveKit agent (fixed)" \
    --timeout-seconds 600 \
    --parameters "commands=[
        \"set -e\",

        \"echo 'Stopping old app'\",
        \"pkill -f 'pnpm dev' 2>/dev/null || true\",
        \"fuser -k 3000/tcp 2>/dev/null || true\",

        \"echo 'Reset app directory'\",
        \"cd /\", 
        \"rm -rf '$APP_DIR'\",
        \"mkdir -p '$APP_DIR'\",
        \"cd '$APP_DIR'\",

        \"echo 'Clone repository'\",
        \"git clone '$GIT_REPO' .\",
        \"rm -rf .git\",

        \"echo 'Create .env.local'\",
        \"cat > .env.local <<EOF\",
        \"LIVEKIT_API_KEY=$LIVEKIT_API_KEY\",
        \"LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET\",
        \"LIVEKIT_URL=$LIVEKIT_URL\",
        \"EOF\",
        \"chmod 600 .env.local\",

        \"echo 'Fix ownership'\",
        \"chown -R ec2-user:ec2-user '$APP_DIR'\",

        \"echo 'Ensure pnpm is installed'\",
        \"command -v pnpm >/dev/null 2>&1 || npm install -g pnpm\",

        \"echo 'Clean previous build'\",
        \"rm -rf '$APP_DIR/.next'\",

        \"echo 'Install dependencies (as ec2-user)'\",
        \"sudo -u ec2-user bash -c 'cd $APP_DIR && pnpm install'\",

        \"echo 'Start agent (as ec2-user on port 3000)'\",
        \"sudo -u ec2-user bash -c 'cd $APP_DIR && PORT=3000 nohup pnpm dev > agent.log 2>&1 &'\",

        \"sleep 3\",
        \"ps aux | grep -E '(node|pnpm)' | grep -v grep\",
        \"echo '✅ Agent running on port 3000'\"
    ]" \
    --region "$REGION"

echo "⏳ Waiting 20 seconds for agent startup..."
sleep 20

# Print access URLs
for INSTANCE_ID in $INSTANCE_IDS; do
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text \
        --region "$REGION")
    echo "🌍 Agent URL: http://$PUBLIC_IP:3000"
done

echo "🎉 Deployment completed successfully!"
