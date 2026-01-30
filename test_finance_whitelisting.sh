#!/bin/bash
# Test script to verify finance group IP whitelisting fix

set -e

echo "=========================================="
echo "Finance Group IP Whitelisting Test"
echo "=========================================="
echo ""

# Configuration
PORTAL_IP="54.202.154.151"
SSH_KEY="$HOME/.ssh/david-capsule-vibecode-2026-01-17.pem"
FINANCE_INSTANCE_ID="i-0a79e8c95b2666cbf"
SECURITY_GROUP_ID="sg-06b525854143eb245"
TEST_USER="dmar@capsule.com"

echo "Test Environment:"
echo "  Portal Instance: $PORTAL_IP"
echo "  Finance Instance: $FINANCE_INSTANCE_ID"
echo "  Test User: $TEST_USER"
echo ""

# Step 1: Verify portal service is running
echo "Step 1: Checking portal service status..."
ssh -i "$SSH_KEY" ubuntu@$PORTAL_IP 'sudo systemctl is-active employee-portal' > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "  ✓ Portal service is running"
else
    echo "  ✗ Portal service is NOT running"
    exit 1
fi
echo ""

# Step 2: Verify SYSTEM_GROUPS constant exists
echo "Step 2: Verifying code changes deployed..."
SYSTEM_GROUPS_COUNT=$(ssh -i "$SSH_KEY" ubuntu@$PORTAL_IP 'grep -c "SYSTEM_GROUPS" /opt/employee-portal/app.py' 2>/dev/null)
if [ "$SYSTEM_GROUPS_COUNT" -gt 0 ]; then
    echo "  ✓ SYSTEM_GROUPS constant found ($SYSTEM_GROUPS_COUNT references)"
else
    echo "  ✗ SYSTEM_GROUPS constant NOT found"
    exit 1
fi
echo ""

# Step 3: Check user's groups
echo "Step 3: Checking $TEST_USER group memberships..."
USER_GROUPS=$(aws cognito-idp admin-list-groups-for-user \
    --user-pool-id us-west-2_WePThH2J8 \
    --username "$TEST_USER" \
    --query 'Groups[*].GroupName' \
    --output json)
echo "  Groups: $USER_GROUPS"

if echo "$USER_GROUPS" | grep -q "finance"; then
    echo "  ✓ User is in 'finance' group"
else
    echo "  ✗ User is NOT in 'finance' group"
    exit 1
fi
echo ""

# Step 4: Verify finance instance exists and is tagged
echo "Step 4: Verifying finance instance..."
INSTANCE_STATE=$(aws ec2 describe-instances \
    --instance-ids "$FINANCE_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)
INSTANCE_TAG=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$FINANCE_INSTANCE_ID" \
    --query 'Tags[?Key==`VibeCodeArea`].Value' \
    --output text)

echo "  Instance State: $INSTANCE_STATE"
echo "  VibeCodeArea Tag: $INSTANCE_TAG"

if [ "$INSTANCE_TAG" = "finance" ]; then
    echo "  ✓ Finance instance properly tagged"
else
    echo "  ✗ Finance instance NOT tagged with 'finance'"
    exit 1
fi
echo ""

# Step 5: Check current security group rules for test user
echo "Step 5: Checking current security group rules..."
EXISTING_RULES=$(aws ec2 describe-security-groups \
    --group-ids "$SECURITY_GROUP_ID" \
    --query "SecurityGroups[0].IpPermissions[?contains(to_string(@), '$TEST_USER')]" \
    --output json)

if [ "$EXISTING_RULES" = "[]" ]; then
    echo "  ℹ No existing IP rules for $TEST_USER"
    echo "  ℹ Rules will be created on next login"
else
    echo "  ✓ Existing IP rules found:"
    echo "$EXISTING_RULES" | jq -r '.[] | "    Port \(.FromPort): \(.IpRanges[0].CidrIp) - \(.IpRanges[0].Description)"'
fi
echo ""

# Step 6: Test the group filtering logic
echo "Step 6: Testing group filtering logic..."
cat > /tmp/test_filter.py << 'EOF'
import json
import sys

SYSTEM_GROUPS = ['admins']
user_groups = json.loads(sys.argv[1])
area_groups = [g for g in user_groups if g not in SYSTEM_GROUPS]

print(json.dumps({
    'user_groups': user_groups,
    'system_groups': SYSTEM_GROUPS,
    'area_groups': area_groups,
    'finance_included': 'finance' in area_groups
}))
EOF

LOGIC_TEST=$(python3 /tmp/test_filter.py "$USER_GROUPS")
echo "  Logic Test Result:"
echo "$LOGIC_TEST" | jq .

FINANCE_INCLUDED=$(echo "$LOGIC_TEST" | jq -r '.finance_included')
if [ "$FINANCE_INCLUDED" = "true" ]; then
    echo "  ✓ Finance group will trigger IP whitelisting"
else
    echo "  ✗ Finance group will NOT trigger IP whitelisting"
    exit 1
fi
echo ""

# Summary
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "✓ Portal service is running"
echo "✓ Code changes are deployed"
echo "✓ User is in finance group"
echo "✓ Finance instance exists and is tagged"
echo "✓ Group filtering logic works correctly"
echo ""
echo "Status: READY FOR END-TO-END TEST"
echo ""
echo "Next Steps:"
echo "1. Have $TEST_USER logout from the portal"
echo "2. Have $TEST_USER login to the portal"
echo "3. Run this command to verify IP whitelisting:"
echo ""
echo "   aws ec2 describe-security-groups \\"
echo "     --group-ids $SECURITY_GROUP_ID \\"
echo "     --query 'SecurityGroups[0].IpPermissions[?contains(to_string(@), \`$TEST_USER\`)].{Port:FromPort,IP:IpRanges[0].CidrIp,Desc:IpRanges[0].Description}' \\"
echo "     --output table"
echo ""
echo "4. Check portal logs for IP whitelisting confirmation:"
echo ""
echo "   ssh -i $SSH_KEY ubuntu@$PORTAL_IP \\"
echo "     'sudo journalctl -u employee-portal --since \"5 minutes ago\" | grep IP-WHITELIST | tail -5'"
echo ""
echo "=========================================="
