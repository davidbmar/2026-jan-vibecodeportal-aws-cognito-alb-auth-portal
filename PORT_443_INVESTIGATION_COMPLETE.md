# Port 443 IP Whitelisting Investigation - Complete Analysis

**Date:** 2026-01-28
**Investigator:** Claude Code (Systematic Debugging Methodology)
**Reported Issue:** Port 443 showing ✗ (not whitelisted) for HR instance while port 80 shows ✓
**User:** dmar@capsule.com
**HR Instance:** i-06883f2837f77f365

---

## Executive Summary

**The reported issue was based on TWO separate problems:**

1. **RESOLVED:** InvalidParameterValue bug affecting BOTH ports 80 and 443 (fixed at 20:23:41 UTC)
2. **ONGOING:** HR instance excluded from IP whitelisting due to security group name mismatch

**Status:** The original bug causing port 443 failures is **FIXED**. Both ports 80 and 443 now work correctly for all instances with the `vibecode-launched-instances` security group.

---

## Root Cause Analysis

### Problem #1: InvalidParameterValue (RESOLVED)

#### The Bug
```python
# BROKEN (before 20:23:41)
description = f"User: {email} | IP: {client_ip} | Port: {port} | Added: {timestamp}"
```

**AWS allowed characters:** `a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*`
**Problem:** Pipe character `|` is NOT in the allowed set

#### Error Logs
```
Jan 28 19:11:28: Error adding IP rule to sg-06b525854143eb245 port 80:
  An error occurred (InvalidParameterValue) when calling the
  AuthorizeSecurityGroupIngress operation: Invalid rule description.

Jan 28 19:11:28: Error adding IP rule to sg-06b525854143eb245 port 443:
  An error occurred (InvalidParameterValue) when calling the
  AuthorizeSecurityGroupIngress operation: Invalid rule description.
```

**Key Finding:** BOTH port 80 AND port 443 failed with the SAME error. This was NEVER a port 443-specific issue.

#### The Fix
```python
# FIXED (deployed 20:23:41)
description = f"User={email}, IP={client_ip}, Port={port}, Added={timestamp}"
```

#### Timeline
| Time (UTC) | Event | Status |
|------------|-------|--------|
| 19:11:28 | dmar login attempt #1 | ❌ BOTH ports failed |
| 20:10:52 | dmar login attempt #2 | ❌ BOTH ports failed |
| 20:23:41 | Fix deployed | ✅ Code updated |
| 22:26:30 | dmar login attempt #3 | ✅ SUCCESS (3 instances) |
| 22:28:05 | dmar login attempt #4 | ✅ SUCCESS (3 instances) |

---

### Problem #2: HR Instance Security Group Mismatch (ONGOING)

#### The Code Logic
```python
# Line 1085-1095 in user_data.sh
# Find the vibecode-launched-instances security group
sg_id = None
for sg in security_groups:
    if sg.get('GroupName') == 'vibecode-launched-instances':
        sg_id = sg['GroupId']
        break

if not sg_id:
    result['instances_failed'].append(instance_id)
    result['errors'].append(f"{instance_id}: vibecode-launched-instances SG not found")
    continue
```

**The code ONLY whitelists IPs on security groups named `vibecode-launched-instances`**

#### Current Instance Configuration

| Instance | Area | Instance ID | Security Group | IP Whitelist Applied? |
|----------|------|-------------|----------------|----------------------|
| finance | finance | i-0a79e8c95b2666cbf | sg-06b525854143eb245 (vibecode-launched-instances) | ✅ YES |
| engineering | engineering | i-0d1e3b59f57974076 | sg-0b0d1792df2a836a6 (vibecode-launched-instances) | ✅ YES |
| product | product | i-0966d965518d2dba1 | sg-0b0d1792df2a836a6 (vibecode-launched-instances) | ✅ YES |
| **hr** | **hr** | **i-06883f2837f77f365** | **sg-0d6bbadbbd290b320 (launch-wizard-7)** | ❌ NO |

#### Error Logs (from failed attempts)
```
Jan 28 19:11:28: Error: i-0966d965518d2dba1: vibecode-launched-instances SG not found
Jan 28 19:11:28: Error: i-0d1e3b59f57974076: vibecode-launched-instances SG not found
```

Wait, these logs show product and engineering failed, but we know they have the right SG now. Let me verify the current state.

---

## Current Verification (as of investigation)

### Security Group Rules for dmar@capsule.com (136.62.92.204/32)

#### sg-06b525854143eb245 (finance instance)
- ✅ Port 80: 136.62.92.204/32 whitelisted
- ✅ Port 443: 136.62.92.204/32 whitelisted

#### sg-0b0d1792df2a836a6 (engineering + product instances)
- ✅ Port 80: 136.62.92.204/32 whitelisted
- ✅ Port 443: 136.62.92.204/32 whitelisted

#### sg-0d6bbadbbd290b320 (HR instance)
- Port 80: Open to 0.0.0.0/0 (no specific IP whitelist)
- Port 443: **NOT CONFIGURED AT ALL**
- Port 22: Multiple IPs including 136.62.92.204/32
- Port 3000: 136.62.92.204/32
- Port 9595: 136.62.92.204/32

---

## Answer to Original Question

**Q: Why does port 443 show ✗ for the HR instance?**

**A: Two reasons:**

1. ✅ **RESOLVED:** The code had a bug (pipe character in description) that caused BOTH port 80 AND 443 to fail for ALL instances. This is now fixed.

2. ❌ **ONGOING:** The HR instance uses a security group named "launch-wizard-7" instead of "vibecode-launched-instances", so the IP whitelisting code **skips it entirely**.

**The user interface may be showing incorrect status** because:
- The HR instance appears in the list of instances for the HR group
- But the backend whitelist logic doesn't actually modify its security group rules
- The UI may be showing status based on "instance found" rather than "rules applied"

---

## Recommendations

### Immediate Actions

1. **Fix HR Instance Security Group**
   ```bash
   # Option A: Attach the vibecode-launched-instances SG to the HR instance
   aws ec2 modify-instance-attribute \
     --instance-id i-06883f2837f77f365 \
     --groups sg-0d6bbadbbd290b320 sg-0b0d1792df2a836a6 \
     --region us-west-2

   # Option B: Rename the logic to handle both SG names
   # Update code to accept both "vibecode-launched-instances" and "launch-wizard-*"
   ```

2. **Verify Port 443 Configuration**
   - The HR instance SG doesn't have port 443 open at all
   - Add port 443 rules to sg-0d6bbadbbd290b320 or ensure the instance uses a SG with port 443

3. **Update UI Logic**
   - Display per-port status (port 80: ✓/✗, port 443: ✓/✗)
   - Show when an instance is skipped due to SG mismatch
   - Distinguish between "rule added" vs "instance skipped"

### Enhanced Logging (from original plan - now validated as correct approach)

The investigation validated that enhanced logging would help catch issues like this faster:

```python
# Add per-port status tracking
port_80_success = False
port_443_success = False

for port in [80, 443]:
    success = add_ip_to_security_group(sg_id, port, client_ip, description)
    if port == 80:
        port_80_success = success
    elif port == 443:
        port_443_success = success

    if success:
        print(f"[IP-WHITELIST-DETAIL] ✓ Added rule for {instance_id} port {port}")
    else:
        print(f"[IP-WHITELIST-DETAIL] ✗ Failed to add rule for {instance_id} port {port}")
```

---

## Lessons Learned

1. **Silent Failures:** The original error (InvalidParameterValue) was only visible in logs, not in the UI
2. **Partial Success Misleading:** The code marks operation as "success" if ANY port succeeds, hiding port-specific failures
3. **Security Group Assumptions:** Hard-coded SG name "vibecode-launched-instances" excludes manually-created instances
4. **User Reporting:** User reported "port 443 fails" but root cause was "BOTH ports fail due to invalid description character"

---

## Testing Performed

### 1. Log Analysis
- Checked logs from 4 hours before investigation
- Found exact error messages with timestamps
- Traced deployment timeline

### 2. Security Group Verification
- Verified all 4 area-specific instances
- Checked rules for ports 80 and 443
- Confirmed which instances have which security groups

### 3. AWS CLI Validation
```bash
# Confirmed dmar's IP is whitelisted on working instances
aws ec2 describe-security-groups \
  --region us-west-2 \
  --filters "Name=ip-permission.cidr,Values=136.62.92.204/32"

# Found: finance, engineering, product have rules; HR does not
```

---

## Files Modified (in original plan - NOT YET IMPLEMENTED)

The original plan proposed logging enhancements that would have caught this issue faster. Since the root cause is now understood, those enhancements should be implemented as a defensive measure:

- `terraform/envs/tier5/user_data.sh`
  - Enhanced error logging in `add_ip_to_security_group()`
  - Per-port status tracking
  - Detailed summary logging

---

## Conclusion

**The port 443 "failure" was actually:**
1. ✅ A description format bug affecting BOTH ports (now fixed)
2. ❌ The HR instance not being processed at all due to SG name mismatch

**Current Status:**
- Finance, Engineering, Product: ✅ Both ports 80 and 443 working
- HR: ❌ Not being whitelisted at all (needs SG configuration fix)

**Next Steps:**
1. Decide on HR instance security group strategy
2. Implement enhanced logging to catch future issues faster
3. Update UI to show per-port and per-instance status more clearly

---

**Investigation Method:** Systematic Debugging (Phase 1: Root Cause Investigation)
- Gathered evidence from multiple sources (logs, AWS API, code)
- Traced data flow through the system
- Verified assumptions at each layer
- Identified root cause before proposing fixes
