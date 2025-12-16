#!/bin/bash
set -u

# ================= Configuration =================
ASG_NAME="staging-agent-asg-20251216003644356900000005"  # Your ASG name
REGION="us-east-2"                # AWS region (us-east-2 as per your locals)
APP_DIR="/opt/agent"             # Deployment directory on EC2
USER="ec2-user"                   # EC2 user
GIT_REPO="https://github.com/livekit-examples/agent-starter-react.git"
# =================================================

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

echo "🚀 Sending deployment command via SSM..."
COMMAND_ID=$(aws ssm send-command \
    --instance-ids $INSTANCE_IDS \
    --document-name "AWS-RunShellScript" \
    --comment "Clone repository via GitHub Actions" \
    --parameters "commands=[
        \"# Clean and prepare directory\",
        \"rm -rf '$APP_DIR'/* 2>/dev/null || true\",
        \"mkdir -p '$APP_DIR'\",
        \"cd '$APP_DIR'\",
        \"\",
        \"# Clone the repository\",
        \"echo 'Cloning $GIT_REPO...'\",
        \"git clone '$GIT_REPO' .\",
        \"\",
        \"# Set permissions\",
        \"chown -R $USER:$USER '$APP_DIR'\",
        \"chmod -R 755 '$APP_DIR'\",
        \"\",
        \"# Verify deployment\",
        \"echo 'Repository cloned successfully to $APP_DIR'\",
        \"echo 'Files:'\",
        \"ls -la\"
    ]" \
    --query "Command.CommandId" \
    --output text \
    --region "$REGION")

echo "📄 SSM Command ID: $COMMAND_ID"

# ================= Wait and fetch logs per instance =================
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

    STDERR=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "StandardErrorContent" \
        --output text \
        --region "$REGION")

    echo "📤 Standard Output:"
    echo "$OUTPUT"
    echo "📥 Standard Error:"
    echo "$STDERR"
done

echo "🎉 Repository cloned on all instances."