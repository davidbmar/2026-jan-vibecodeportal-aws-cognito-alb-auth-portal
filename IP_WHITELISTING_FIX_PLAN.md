# IP Whitelisting Fix - Action Plan & Test Plan

## Scope
Fix two specific bugs preventing IP whitelisting on login:
1. Invalid pipe character in security group rule descriptions
2. Missing vibecode-launched-instances security group on 2 instances

**Out of Scope:**
- Refactoring unrelated code
- Adding new features
- Changing whitelisting logic
- Modifying security group cleanup/removal logic

---

## Action Plan

### Step 1: Fix Security Group Rule Description Format

**File:** `terraform/envs/tier5/user_data.sh`
**Location:** Line ~1464 (in IP whitelisting function)

**Current Code:**
```python
description = f"User: {email} | IP: {client_ip} | Port: {port} | Added: {timestamp}"
```

**Change To:**
```python
description = f"User={email}, IP={client_ip}, Port={port}, Added={timestamp}"
```

**Rationale:**
- Replace pipe `|` with comma `,` (AWS-allowed character)
- Use `=` for key-value pairs (AWS-allowed)
- Maintains readability and parseability
- Stays within 256 character limit

**Expected Description Output:**
```
User=dmar@capsule.com, IP=136.62.92.204, Port=80, Added=2026-01-28T20:15:00.000000
```

---

### Step 2: Attach vibecode-launched-instances Security Group

**Target Instances:**
- i-0d1e3b59f57974076 (vibe-code-david-mar-server, engineering)
- i-0966d965518d2dba1 (vibe-code-john-eric-server, product)

**Commands:**

```bash
# Engineering instance - ADD vibecode-launched-instances while keeping launch-wizard-8
aws ec2 modify-instance-attribute \
  --instance-id i-0d1e3b59f57974076 \
  --groups sg-0d485b4ffe8c8f886 sg-06b525854143eb245 \
  --region us-west-2

# Product instance - ADD vibecode-launched-instances while keeping launch-wizard-7  
aws ec2 modify-instance-attribute \
  --instance-id i-0966d965518d2dba1 \
  --groups sg-0d6bbadbbd290b320 sg-06b525854143eb245 \
  --region us-west-2
```

**Verification:**
```bash
# Confirm both security groups are attached
aws ec2 describe-instances \
  --instance-ids i-0d1e3b59f57974076 i-0966d965518d2dba1 \
  --query 'Reservations[*].Instances[*].[InstanceId,SecurityGroups[*].GroupName]' \
  --output table \
  --region us-west-2
```

**Expected Output:**
```
| i-0d1e3b59f57974076 | [launch-wizard-8, vibecode-launched-instances] |
| i-0966d965518d2dba1 | [launch-wizard-7, vibecode-launched-instances] |
```

---

### Step 3: Deploy Updated Portal Code

**Process:**

1. Extract updated app.py from user_data.sh
2. Substitute variables (USER_POOL_ID, CLIENT_SECRET, etc.)
3. Backup current app.py on portal server
4. Deploy new app.py
5. Restart employee-portal service

**Deployment Script:**
```bash
./deploy_passwordless.sh  # Existing script, or create new focused script
```

**Verification:**
```bash
# Check service is running
ssh ubuntu@54.202.154.151 'sudo systemctl status employee-portal'

# Verify description format in deployed code
ssh ubuntu@54.202.154.151 'grep "description = f\"User=" /opt/employee-portal/app.py'
```

---

### Step 4: Clear Old Failed Rules (Optional Cleanup)

**Check for failed/partial rules:**
```bash
aws ec2 describe-security-groups \
  --group-ids sg-06b525854143eb245 \
  --query 'SecurityGroups[*].IpPermissions[?FromPort==`80` || FromPort==`443`]' \
  --output json \
  --region us-west-2
```

**If any rules exist with old pipe format, remove them:**
```bash
# Only if needed - check output first
aws ec2 revoke-security-group-ingress \
  --group-id sg-06b525854143eb245 \
  --ip-permissions '[...]' \
  --region us-west-2
```

---

## Test Plan

### Pre-Test Setup

**Environment:**
- Portal URL: https://portal.capsule-playground.com
- Test User: dmar@capsule.com (groups: finance, product, engineering)
- Test IP: Will be detected automatically by portal

**Required Tools:**
- AWS CLI access
- SSH access to portal server
- Browser for portal access

---

### Test 1: Verify Description Format Change

**Objective:** Confirm pipe character removed from code

**Steps:**
```bash
# 1. Check deployed code
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 \
  'grep -n "description = f" /opt/employee-portal/app.py | grep -i user'

# 2. Verify NO pipe characters in description
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 \
  'grep "description = f\"User" /opt/employee-portal/app.py | grep "|"'
```

**Expected Results:**
- Line shows: `description = f"User={email}, IP={client_ip}, Port={port}, Added={timestamp}"`
- No output from pipe character check (exit code 1)

**Pass Criteria:** ✅ No pipe characters in description format

---

### Test 2: Verify Security Groups Attached

**Objective:** Confirm vibecode-launched-instances SG attached to all 3 instances

**Steps:**
```bash
aws ec2 describe-instances \
  --instance-ids i-0a79e8c95b2666cbf i-0d1e3b59f57974076 i-0966d965518d2dba1 \
  --query 'Reservations[*].Instances[*].[InstanceId,SecurityGroups[?GroupName==`vibecode-launched-instances`].GroupId|[0]]' \
  --output table \
  --region us-west-2
```

**Expected Results:**
```
| i-0a79e8c95b2666cbf | sg-06b525854143eb245 |  ← Finance (was already correct)
| i-0d1e3b59f57974076 | sg-06b525854143eb245 |  ← Engineering (NEW)
| i-0966d965518d2dba1 | sg-06b525854143eb245 |  ← Product (NEW)
```

**Pass Criteria:** ✅ All 3 instances show sg-06b525854143eb245

---

### Test 3: Portal Service Health Check

**Objective:** Verify portal is running without errors

**Steps:**
```bash
# 1. Check service status
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 \
  'sudo systemctl status employee-portal'

# 2. Check for errors in recent logs
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 \
  'sudo journalctl -u employee-portal --since "5 minutes ago" | grep -i error'

# 3. Test health endpoint
curl -s https://portal.capsule-playground.com/health
```

**Expected Results:**
- Service status: `active (running)`
- No Python tracebacks in logs
- Health endpoint returns: `{"status":"healthy"}`

**Pass Criteria:** ✅ Service running, no errors, health check passes

---

### Test 4: End-to-End IP Whitelisting Test

**Objective:** Verify IP whitelisting works on login for all 3 instances

**Steps:**

1. **Logout** (clear current session)
   - Navigate to: https://portal.capsule-playground.com/logout

2. **Login** as dmar@capsule.com
   - Enter email: dmar@capsule.com
   - Receive 6-digit code via email
   - Enter code and submit

3. **Check portal logs** for whitelisting activity
   ```bash
   ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 \
     'sudo journalctl -u employee-portal --since "2 minutes ago" | grep -A10 "IP-WHITELIST"'
   ```

4. **Navigate to EC2 Resources page**
   - Click "EC2 Resources" or go to: https://portal.capsule-playground.com/ec2-resources

5. **Verify whitelisting status**
   - Check each instance's port status (80 and 443)
   - Should see ✓ (checkmark) not x (cross)

**Expected Log Output:**
```
[IP-WHITELIST] 2026-01-28T20:XX:XX | USER: dmar@capsule.com | IP: X.X.X.X | STATUS: success
  Updated: 3, Failed: 0
  Success: i-0a79e8c95b2666cbf (ports: 80, 443)
  Success: i-0d1e3b59f57974076 (ports: 80, 443)
  Success: i-0966d965518d2dba1 (ports: 80, 443)
```

**Expected Portal UI:**

| Instance | Name | Area | Port 80 | Port 443 |
|----------|------|------|---------|----------|
| i-0a79e8c95b2666cbf | 2026-01-jan-28... | finance | ✓ | ✓ |
| i-0d1e3b59f57974076 | vibe-code-david-mar... | engineering | ✓ | ✓ |
| i-0966d965518d2dba1 | vibe-code-john-eric... | product | ✓ | ✓ |

**Pass Criteria:** ✅ All 3 instances show ✓ for both ports 80 and 443

---

### Test 5: Verify Security Group Rules Created

**Objective:** Confirm AWS security group rules were actually added

**Steps:**
```bash
# Get your test IP from portal logs
TEST_IP=$(ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 \
  'sudo journalctl -u employee-portal --since "5 minutes ago" | grep "IP-WHITELIST" | head -1 | grep -oP "IP: \K[0-9.]+')

echo "Testing with IP: $TEST_IP"

# Check security group rules
aws ec2 describe-security-groups \
  --group-ids sg-06b525854143eb245 \
  --query "SecurityGroups[*].IpPermissions[?contains(IpRanges[].CidrIp, '$TEST_IP/32')]" \
  --output json \
  --region us-west-2
```

**Expected Results:**
- Rules exist for $TEST_IP/32 on ports 80 and 443
- Description format: `User=dmar@capsule.com, IP=X.X.X.X, Port=80, Added=...`
- No pipe characters in description

**Pass Criteria:** ✅ 2 rules found (port 80 and 443) with valid descriptions

---

### Test 6: Test Multiple Logins (Idempotency)

**Objective:** Verify repeated logins don't create duplicate rules

**Steps:**

1. **Logout and login again** as dmar@capsule.com
2. **Check logs** for IP change detection
   ```bash
   ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 \
     'sudo journalctl -u employee-portal --since "2 minutes ago" | grep "IP change detected\|Using existing IP"'
   ```

3. **Verify rule count** hasn't increased
   ```bash
   aws ec2 describe-security-groups \
     --group-ids sg-06b525854143eb245 \
     --query 'SecurityGroups[*].IpPermissions[?FromPort==`80`].IpRanges[*].CidrIp' \
     --output json \
     --region us-west-2 | grep -o '".*"' | wc -l
   ```

**Expected Results:**
- Log shows: "Using existing IP: X.X.X.X - no changes needed"
- Rule count remains at 2 (one for port 80, one for port 443)
- No duplicate rules created

**Pass Criteria:** ✅ No duplicate rules, idempotent behavior

---

### Test 7: Rollback Test (Safety Verification)

**Objective:** Verify rollback capability if issues arise

**Steps:**
```bash
# 1. List available backups
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 \
  'ls -lht /opt/employee-portal/app.py.backup* | head -5'

# 2. If needed, restore from backup (DO NOT RUN unless needed)
# ssh ubuntu@54.202.154.151 'sudo cp /opt/employee-portal/app.py.backup.XXXXX /opt/employee-portal/app.py'
# ssh ubuntu@54.202.154.151 'sudo systemctl restart employee-portal'
```

**Pass Criteria:** ✅ Backups exist and are recent

---

## Success Criteria Summary

All tests must pass:

- ✅ Test 1: Description format uses comma, not pipe
- ✅ Test 2: All 3 instances have vibecode-launched-instances SG
- ✅ Test 3: Portal service running without errors
- ✅ Test 4: All 3 instances show ✓ for ports 80 and 443
- ✅ Test 5: Security group rules exist with valid descriptions
- ✅ Test 6: Repeated logins are idempotent
- ✅ Test 7: Rollback capability verified

**Overall Result:** IP whitelisting works correctly for all instances on user login.

---

## Rollback Plan

If any test fails:

1. **Stop immediately** - Do not proceed with remaining tests
2. **Restore from backup:**
   ```bash
   ssh ubuntu@54.202.154.151 'sudo cp /opt/employee-portal/app.py.backup.LATEST /opt/employee-portal/app.py'
   ssh ubuntu@54.202.154.151 'sudo systemctl restart employee-portal'
   ```
3. **Remove security groups if needed:**
   ```bash
   # Only restore original SGs if modification caused issues
   aws ec2 modify-instance-attribute --instance-id i-0d1e3b59f57974076 --groups sg-0d485b4ffe8c8f886 --region us-west-2
   aws ec2 modify-instance-attribute --instance-id i-0966d965518d2dba1 --groups sg-0d6bbadbbd290b320 --region us-west-2
   ```
4. **Investigate failure** before retry

---

## Post-Fix Recommendations (Future Work - Out of Scope)

**Not included in this fix:**
- Remove 0.0.0.0/0 rules from launch-wizard-7 and launch-wizard-8 SGs
- Implement automated testing for IP whitelisting
- Add monitoring/alerting for whitelisting failures
- Refactor whitelisting code for better modularity

These can be addressed in a separate task after verifying the current fix works.

