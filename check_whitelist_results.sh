#!/bin/bash
echo "================================================"
echo "Checking IP Whitelisting Results"
echo "================================================"
echo ""

# Get latest login event
echo "Latest Login Event:"
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 \
  'sudo journalctl -u employee-portal --since "10 minutes ago" | grep "IP-WHITELIST" | tail -20'

echo ""
echo "================================================"
echo "Current Security Group Rules:"
echo "================================================"

# Get the test IP from logs
TEST_IP=$(ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 \
  'sudo journalctl -u employee-portal --since "10 minutes ago" | grep "IP-WHITELIST.*IP:" | tail -1' | grep -oP "IP: \K[0-9.]+")

if [ -z "$TEST_IP" ]; then
    echo "No recent login found. Please login first."
    exit 1
fi

echo "Test IP: $TEST_IP"
echo ""

# Check rules in new VPC security group (finance)
echo "Finance Instance Security Group (sg-06b525854143eb245):"
aws ec2 describe-security-groups \
  --group-ids sg-06b525854143eb245 \
  --query "SecurityGroups[*].IpPermissions[?contains(IpRanges[].CidrIp, '$TEST_IP/32')].[FromPort,ToPort,IpRanges[0].Description]" \
  --output table \
  --region us-west-2

echo ""

# Check rules in old VPC security group (engineering/product)
echo "Engineering/Product Security Group (sg-0b0d1792df2a836a6):"
aws ec2 describe-security-groups \
  --group-ids sg-0b0d1792df2a836a6 \
  --query "SecurityGroups[*].IpPermissions[?contains(IpRanges[].CidrIp, '$TEST_IP/32')].[FromPort,ToPort,IpRanges[0].Description]" \
  --output table \
  --region us-west-2

echo ""
echo "================================================"
echo "Summary:"
echo "================================================"
echo "Expected: 2 rules per security group (ports 80 and 443)"
echo "Description format: User=dmar@capsule.com, IP=$TEST_IP, Port=XX, Added=..."
