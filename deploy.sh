#!/bin/bash
set -e

ASG_NAME="staging-agent-asg-2025121613551604090000000a"
REGION="us-east-2"
APP_DIR="/opt/agent"
GIT_REPO="https://github.com/livekit-examples/agent-starter-react.git"

# Validate environment variables
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

echo "🚀 Deploying agent code..."
COMMAND_ID=$(aws ssm send-command \
    --instance-ids $INSTANCE_IDS \
    --document-name "AWS-RunShellScript" \
    --comment "Deploy LiveKit agent" \
    --timeout-seconds 300 \
    --parameters "commands=[
        \"set -e\",
        \"echo '1. Installing/updating Nginx...'\",
        \"amazon-linux-extras install -y nginx1 2>/dev/null || true\",
        \"systemctl enable nginx 2>/dev/null || true\",
        \"systemctl start nginx 2>/dev/null || true\",
        \"\",
        \"echo '2. Setting up app directory...'\",
        \"mkdir -p '$APP_DIR'\",
        \"chown -R ec2-user:ec2-user '$APP_DIR'\",
        \"cd '$APP_DIR'\",
        \"\",
        \"echo '3. Cloning repo...'\",
        \"rm -rf * .[^.]* 2>/dev/null || true\",
        \"git clone '$GIT_REPO' .\",
        \"rm -rf .git\",
        \"\",
        \"echo '4. Creating env file...'\",
        \"cat > .env.local <<EOF\",
        \"LIVEKIT_API_KEY=$LIVEKIT_API_KEY\",
        \"LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET\",
        \"LIVEKIT_URL=$LIVEKIT_URL\",
        \"EOF\",
        \"chown ec2-user:ec2-user .env.local\",
        \"\",
        \"echo '5. Installing dependencies...'\",
        \"sudo -u ec2-user pnpm install\",
        \"\",
        \"echo '6. Configuring Nginx...'\",
        \"cat > /etc/nginx/conf.d/agent.conf <<'NGINX'\",
        \"server {\",
        \"    listen 80;\",
        \"    server_name _;\",
        \"    location / {\",
        \"        proxy_pass http://localhost:3000;\",
        \"        proxy_http_version 1.1;\",
        \"        proxy_set_header Upgrade \\\$http_upgrade;\",
        \"        proxy_set_header Connection 'upgrade';\",
        \"        proxy_set_header Host \\\$host;\",
        \"    }\",
        \"}\",
        \"NGINX\",
        \"nginx -t && systemctl reload nginx || echo 'Nginx reload skipped'\",
        \"\",
        \"echo '7. Setting up systemd service...'\",
        \"cat > /etc/systemd/system/agent.service <<'SERVICE'\",
        \"[Unit]\",
        \"Description=LiveKit Agent Starter\",
        \"After=network.target\",
        \"\",
        \"[Service]\",
        \"Type=simple\",
        \"User=ec2-user\",
        \"WorkingDirectory=/opt/agent\",
        \"Environment=NODE_ENV=production\",
        \"ExecStart=/usr/bin/pnpm start\",
        \"Restart=always\",
        \"RestartSec=10\",
        \"\",
        \"[Install]\",
        \"WantedBy=multi-user.target\",
        \"SERVICE\",
        \"\",
        \"echo '8. Starting agent...'\",
        \"systemctl daemon-reload\",
        \"systemctl enable agent\",
        \"systemctl restart agent\",
        \"\",
        \"echo '✅ Deployment complete!'\",
        \"echo 'Agent running on: http://localhost:3000'\",
    ]" \
    --query "Command.CommandId" \
    --output text \
    --region "$REGION")

echo "📄 Command ID: $COMMAND_ID"
echo "⏳ Waiting for deployment..."
sleep 30

for INSTANCE_ID in $INSTANCE_IDS; do
    echo "--- $INSTANCE_ID ---"
    
    OUTPUT=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "StandardOutputContent" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "No output")
    
    STATUS=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query "Status" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "Unknown")
    
    echo "Status: $STATUS"
    echo "Output (last few lines):"
    echo "$OUTPUT" | tail -20
done

echo "🎉 Deployment process completed!"
echo "📋 Agents should be accessible via:"
for INSTANCE_ID in $INSTANCE_IDS; do
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "No public IP")
    echo "  http://$PUBLIC_IP"
done