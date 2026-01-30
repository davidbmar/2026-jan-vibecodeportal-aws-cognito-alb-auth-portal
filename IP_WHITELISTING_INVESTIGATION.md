# IP Whitelisting Investigation Report

## Issue Summary
When dmar@capsule.com logs in, IP whitelisting **partially fails**. Ports 80 and 443 show "x" (not whitelisted) on the EC2 resources page.

---

## Login Event Details

**User:** dmar@capsule.com
**IP Address:** 136.62.92.204
**Groups:** finance, product, engineering
**Timestamp:** 2026-01-28T20:10:52

**Result:** partial_failure
- Updated: 0 instances
- Failed: 3 instances

---

## Root Causes Identified

### 🔴 Problem 1: Invalid Security Group Rule Description

**Error Message:**
```
Error adding IP rule to sg-06b525854143eb245 port 80: 
Invalid rule description. Valid descriptions are strings less than 256 characters 
from the following set: a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*
```

**Current Description Format:**
```python
description = f"User: {email} | IP: {client_ip} | Port: {port} | Added: {timestamp}"
# Example: "User: dmar@capsule.com | IP: 136.62.92.204 | Port: 80 | Added: 2026-01-28T20:10:52.948200"
```

**Issue:** The **pipe character `|`** is NOT in AWS's allowed character set!

**Allowed Characters:**
- Letters: a-zA-Z
- Numbers: 0-9
- Special: `. _ - : / ( ) # , @ [ ] + = & ; { } ! $ *`

**Missing from allowed set:**
- ❌ Pipe `|`
- ❌ Less than `<`
- ❌ Greater than `>`
- ❌ Backslash `\`
- ❌ Quote marks `" '`

---

### 🔴 Problem 2: Wrong Security Groups on 2 Instances

**Instance Details:**

| Instance ID | Name | Area | Current Security Group | Expected |
|-------------|------|------|------------------------|----------|
| i-0a79e8c95b2666cbf | 2026-01-jan-28-vibecode-instance-01 | finance | ✅ sg-06b525854143eb245 (vibecode-launched-instances) | Correct SG, but description fails |
| i-0d1e3b59f57974076 | vibe-code-david-mar-server | engineering | ❌ sg-0d485b4ffe8c8f886 (launch-wizard-8) | Needs vibecode-launched-instances |
| i-0966d965518d2dba1 | vibe-code-john-eric-server | product | ❌ sg-0d6bbadbbd290b320 (launch-wizard-7) | Needs vibecode-launched-instances |

**Current Security Group Rules:**

**sg-06b525854143eb245 (vibecode-launched-instances) - FINANCE instance:**
- Port 80: ❌ No rules (dynamic whitelisting attempted but FAILED)
- Port 443: ❌ No rules (dynamic whitelisting attempted but FAILED)

**sg-0d485b4ffe8c8f886 (launch-wizard-8) - ENGINEERING instance:**
- Port 80: ✅ Open to 0.0.0.0/0 (public)
- Port 443: ✅ Open to 0.0.0.0/0 (public)

**sg-0d6bbadbbd290b320 (launch-wizard-7) - PRODUCT instance:**
- Port 80: ✅ Open to 0.0.0.0/0 (public)

---

## Why User Sees "x" for Ports

The portal checks if the user's IP (136.62.92.204) is whitelisted:

**Finance Instance (i-0a79e8c95b2666cbf):**
- ❌ Port 80: Not whitelisted (rule addition failed)
- ❌ Port 443: Not whitelisted (rule addition failed)
- Shows "x" correctly

**Engineering Instance (i-0d1e3b59f57974076):**
- ✅ Port 80: Actually OPEN to everyone (0.0.0.0/0)
- ✅ Port 443: Actually OPEN to everyone (0.0.0.0/0)
- But portal can't find vibecode-launched-instances SG, so reports as not whitelisted

**Product Instance (i-0966d965518d2dba1):**
- ✅ Port 80: Actually OPEN to everyone (0.0.0.0/0)
- ❌ Port 443: Not open
- But portal can't find vibecode-launched-instances SG, so reports as not whitelisted

---

## Whitelisting Logic Flow

```
1. User logs in successfully
2. Portal extracts user's groups: [finance, product, engineering]
3. Portal finds all instances with VibeCodeArea tag matching user's groups
   - Found: finance instance (i-0a79e8c95b2666cbf)
   - Found: engineering instance (i-0d1e3b59f57974076)
   - Found: product instance (i-0966d965518d2dba1)
4. For each instance, portal looks for "vibecode-launched-instances" security group
5. Portal attempts to add IP rule with description containing pipe "|"
6. AWS rejects all 3 attempts:
   - Finance: Invalid description (pipe character)
   - Engineering: SG not found
   - Product: SG not found
```

---

## Impact Assessment

**Finance Group Instances:**
- ❌ NOT accessible - Whitelisting failed
- Security properly restrictive (no 0.0.0.0/0 rules)
- User CANNOT access on ports 80/443

**Engineering Group Instances:**
- ✅ ACCESSIBLE - Open to everyone (0.0.0.0/0)
- Security TOO permissive
- User CAN access but shouldn't need whitelisting

**Product Group Instances:**
- ⚠️ Port 80 accessible to everyone
- ❌ Port 443 NOT accessible
- Mixed security posture

---

## Fix Required

### Fix 1: Update Security Group Rule Description Format
**File:** `/opt/employee-portal/app.py`

**Current (line ~1464):**
```python
description = f"User: {email} | IP: {client_ip} | Port: {port} | Added: {timestamp}"
```

**Replace pipe `|` with allowed character (colon `:` or semicolon `;`):**
```python
description = f"User: {email} - IP: {client_ip} - Port: {port} - Added: {timestamp}"
# OR
description = f"User={email}, IP={client_ip}, Port={port}, Added={timestamp}"
```

### Fix 2: Attach Correct Security Group to Instances
**Instances needing update:**
- i-0d1e3b59f57974076 (engineering)
- i-0966d965518d2dba1 (product)

**Commands:**
```bash
# Attach vibecode-launched-instances SG to engineering instance
aws ec2 modify-instance-attribute \
  --instance-id i-0d1e3b59f57974076 \
  --groups sg-0d485b4ffe8c8f886 sg-06b525854143eb245 \
  --region us-west-2

# Attach vibecode-launched-instances SG to product instance  
aws ec2 modify-instance-attribute \
  --instance-id i-0966d965518d2dba1 \
  --groups sg-0d6bbadbbd290b320 sg-06b525854143eb245 \
  --region us-west-2
```

**Note:** These commands ADD the vibecode-launched-instances SG while keeping existing SGs.

---

## Verification Steps

After fixes:

1. **Test Description Fix:**
   ```bash
   # Check portal logs for successful rule addition
   ssh ubuntu@54.202.154.151 'sudo journalctl -u employee-portal --since "5 minutes ago" | grep IP-WHITELIST'
   ```

2. **Test Security Group Attachment:**
   ```bash
   # Verify SGs are attached
   aws ec2 describe-instances --instance-ids i-0d1e3b59f57974076 i-0966d965518d2dba1 \
     --query 'Reservations[*].Instances[*].[InstanceId,SecurityGroups[*].GroupName]' \
     --output table --region us-west-2
   ```

3. **Test Login Whitelisting:**
   - Logout from portal
   - Login as dmar@capsule.com
   - Check EC2 Resources page
   - All 3 instances should show ✓ for ports 80 and 443

---

## Security Considerations

**After Fix:**
- Finance instances: Properly whitelisted, access controlled ✅
- Engineering instances: Should have 0.0.0.0/0 rules removed from launch-wizard-8 SG
- Product instances: Should have 0.0.0.0/0 rules removed from launch-wizard-7 SG

**Recommendation:** 
Once whitelisting works, remove the overly permissive 0.0.0.0/0 rules from launch-wizard SGs.

---

## Summary

**2 Bugs Found:**
1. ❌ Invalid pipe character in security group rule description
2. ❌ Two instances missing vibecode-launched-instances security group

**Status:** Both bugs prevent proper IP whitelisting
**Workaround:** Engineering/Product instances accidentally public, so accessible anyway
**Risk:** Finance instances NOT accessible until fixed

