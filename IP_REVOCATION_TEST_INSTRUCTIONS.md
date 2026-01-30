# IP Revocation Test Instructions

## Status: IAM Permission Added ✅

The `ec2:RevokeSecurityGroupIngress` permission has been successfully added to the `employee-portal-ec2-role` IAM role.

## Current Test State

### User: dmar@capsule.com
- **Previous Groups**: finance, engineering, admins
- **Current Groups**: engineering, admins ✅ (finance removed)
- **Finance Instance**: i-0a79e8c95b2666cbf
- **Finance Security Group**: sg-06b525854143eb245

### Orphaned IP Rules (need cleanup)
The user's IP (136.62.92.204/32) is still present on the finance instance security group:
- Port 80: Rule exists ❌ (should be removed)
- Port 443: Rule exists ❌ (should be removed)

## Test Procedure

### Option 1: User Login Test (Recommended)

1. **User logs in to portal**: https://portal.capsule-playground.com
   - Username: dmar@capsule.com
   - Password: [user's password]

2. **Check logs for revocation**:
   ```bash
   ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 \
     "sudo journalctl -u employee-portal --since '2 minutes ago' | grep -E 'dmar@capsule.com|IP-REVOKE'"
   ```

3. **Expected log output**:
   ```
   [IP-REVOKE] User dmar@capsule.com lost access to instances: ['i-0a79e8c95b2666cbf']
   [IP-REVOKE] Removed dmar@capsule.com IP 136.62.92.204 from instance i-0a79e8c95b2666cbf
   [IP-WHITELIST] INSTANCES_ADDED: 0 | INSTANCES_REVOKED: 1 | STATUS: success
   ```

4. **Verify IP rules removed**:
   ```bash
   aws ec2 describe-security-groups \
     --group-ids sg-06b525854143eb245 \
     --query 'SecurityGroups[0].IpPermissions[?(FromPort==`80` || FromPort==`443`)].IpRanges[].[CidrIp, Description]' \
     --output table --region us-west-2 | grep dmar
   ```

   **Expected**: No output (no dmar rules found)

### Option 2: Watch Logs in Real-Time

Run this command and then have the user log in:
```bash
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 \
  "sudo journalctl -u employee-portal -f" | grep --line-buffered -E 'dmar@capsule.com|IP-REVOKE|IP-WHITELIST'
```

## Success Criteria

✅ User can log in successfully
✅ Logs show: "User dmar@capsule.com lost access to instances: ['i-0a79e8c95b2666cbf']"
✅ Logs show: "Removed dmar@capsule.com IP 136.62.92.204 from instance i-0a79e8c95b2666cbf"
✅ Logs show: "INSTANCES_REVOKED: 1"
✅ No "UnauthorizedOperation" errors in logs
✅ Security group no longer contains dmar's IP rules on ports 80 and 443

## Verification Commands

### Check IAM Permission (Already verified ✅)
```bash
aws iam get-role-policy \
  --role-name employee-portal-ec2-role \
  --policy-name employee-portal-ec2-cognito-policy \
  --region us-west-2 \
  --output json | jq -r '.PolicyDocument.Statement[] | select(.Effect=="Allow") | .Action[]?' | grep -i revoke
```

Output: `ec2:RevokeSecurityGroupIngress`

### Check Current User Groups
```bash
aws cognito-idp admin-list-groups-for-user \
  --user-pool-id us-west-2_WePThH2J8 \
  --username dmar@capsule.com \
  --region us-west-2 \
  --query 'Groups[].GroupName' \
  --output table
```

### Check Security Group Rules
```bash
aws ec2 describe-security-groups \
  --group-ids sg-06b525854143eb245 \
  --query 'SecurityGroups[0].IpPermissions[?(FromPort==`80` || FromPort==`443`)].IpRanges[]' \
  --output table --region us-west-2
```

## Rollback (if needed)

If issues arise, remove the permission:
```bash
cd /home/ubuntu/cognito_alb_ec2/terraform/envs/tier5
git diff main.tf  # Review changes
git checkout main.tf  # Revert changes
terraform plan
terraform apply
```

Or manually via AWS Console:
1. Go to IAM → Roles → employee-portal-ec2-role
2. Edit employee-portal-ec2-cognito-policy
3. Remove `ec2:RevokeSecurityGroupIngress` from the Action list

## Files Modified

- `/home/ubuntu/cognito_alb_ec2/terraform/envs/tier5/main.tf` (line 536)
  - Added: `"ec2:RevokeSecurityGroupIngress"`

## Terraform State

- Plan file: `tfplan-iam-revoke-permission`
- Applied: ✅ January 29, 2026
- Resources changed: 1 (aws_iam_role_policy.ec2_cognito)
