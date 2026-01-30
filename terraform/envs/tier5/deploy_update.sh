#!/bin/bash
# Deploy the updated user_data.sh to running portal instance

INSTANCE_ID="i-01ebe3bbad23c0efc"

echo "Copying updated application code to portal instance..."

# Copy the updated Python app section to the instance
aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --comment "Deploy group creation feature" \
    --parameters 'commands=[
        "sudo systemctl stop portal",
        "cd /home/ubuntu",
        "cp app.py app.py.backup.$(date +%Y%m%d_%H%M%S)"
    ]' \
    --output text \
    --query 'Command.CommandId'

echo "Backup created. Now uploading new code..."
