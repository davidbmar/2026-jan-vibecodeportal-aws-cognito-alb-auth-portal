# IP Revocation Feature - Debugging Report

**Date**: 2026-01-29
**User**: dmar@capsule.com
**Issue**: User has incorrect access to instances after IP revocation feature deployment

---

## Executive Summary

✅ **IAM Permission Fix**: Successfully deployed `ec2:RevokeSecurityGroupIngress` permission
❌ **Critical Bug Discovered**: Shared security groups between different areas cause IP whitelisting logic to fail
⚠️ **User Impact**: Users gain unintended access to instances from areas they don't belong to

---

## Test Results

### User State
- **Cognito Groups**: `engineering`, `admins`
- **Area Groups** (for instance access): `engineering` only
- **Expected Access**: Engineering instance only
- **Actual Access**: Engineering + Product instances

### Instance Access Matrix

| Instance | Area | Security Group | Has IP Rules? | User Has Group? | Access Should Be | Access Actually Is |
|----------|------|----------------|---------------|-----------------|------------------|-------------------|
| finance | finance | sg-06b525854143eb245 | ✗ No | ✗ No | ✗ Denied | ✅ Denied (correct) |
| marketing | marketing | sg-06b525854143eb245 | ✗ No | ✗ No | ✗ Denied | ✅ Denied (correct) |
| hr | hr | sg-0d6bbadbbd290b320 | ✗ No | ✗ No | ✗ Denied | ✅ Denied (correct) |
| engineering | engineering | **sg-0b0d1792df2a836a6** | ✓ Yes | ✓ Yes | ✓ Allowed | ✅ Allowed (correct) |
| product | product | **sg-0b0d1792df2a836a6** | ✓ Yes | ✗ No | ✗ Denied | ❌ **Allowed (BUG)** |

---

## Root Cause Analysis

### Bug #1: Shared Security Groups Between Areas 🔴 CRITICAL

**Problem**: Engineering and product instances share the same security group (`sg-0b0d1792df2a836a6`).

**Impact**: When a user's IP is whitelisted for engineering, they automatically gain access to product because both instances use the same security group.

**How It Happens**:
1. User logs in with `engineering` group
2. Portal adds user's IP to engineering instance's security group (sg-0b0d1792df2a836a6)
3. Product instance ALSO uses sg-0b0d1792df2a836a6
4. User's IP rule in sg-0b0d1792df2a836a6 grants access to BOTH instances
5. Portal detects user shouldn't have product access → attempts to revoke
6. Revocation removes IP from sg-0b0d1792df2a836a6 → affects BOTH instances
7. Portal re-adds IP for engineering → product access comes back
8. **Result**: Infinite loop every login, user keeps unintended product access

**Evidence from Logs**:
```
First login (04:15:09):
  [IP-REVOKE] Lost access to: i-0a79e8c95b2666cbf (finance), i-0966d965518d2dba1 (product), i-00417dd8a649affa9 (marketing)
  ✅ Removed IP from all 3 instances
  Result: INSTANCES_REVOKED: 3

Second login (04:17:15):
  [IP-REVOKE] Lost access to: i-0966d965518d2dba1 (product)  ← Only product this time!
  ✅ Removed IP from product
  Result: INSTANCES_REVOKED: 1
```

The fact that product appears AGAIN on the second login proves the revocation is being undone.

**Design Assumption Violated**: The portal assumes each area has its own security group, or at minimum, instances from different areas don't share security groups.

---

### Bug #2: Instance Display Shows All Areas (By Design, Not a Bug)

**Observation**: User sees all instances in the table, not just their areas.

**Analysis**: This is **intentional behavior**:
- Portal API endpoint `/api/ec2/instances` returns ALL instances with VibeCodeArea tag
- Code comment states: "Get ALL instances with VibeCodeArea tag (not filtered by user groups)"
- The checkmarks (✓ ✗) indicate which instances the user actually has access to
- This allows users to see the full infrastructure while clearly showing their access level

**Verdict**: Not a bug, working as designed.

---

## Code Analysis

### Relevant Functions

#### 1. `get_instances_user_is_whitelisted_on()` (Line 999)
Iterates through ALL instances and checks if user's IP exists in each instance's security group.

**Issue**: Returns an instance ID whenever the IP is found in that instance's security group, without considering that multiple instances might share the same security group.

```python
# Simplified logic:
for instance in all_instances:
    for sg in instance.security_groups:
        if user_ip in sg.ip_rules:
            whitelisted_instances.append(instance_id)  # ← Adds instance
```

When engineering and product share sg-0b0d1792df2a836a6, both get added to the list.

#### 2. `whitelist_user_ip_on_instances()` (Line 1063)
Main whitelisting function that:
1. Gets instances user SHOULD have access to (based on groups)
2. Gets instances user IS currently whitelisted on
3. Calculates lost access = whitelisted - should_have
4. Revokes from lost access instances
5. Adds to current access instances

**Issue**: Step 4 and step 5 conflict when instances share security groups:
- Step 4 removes IP from product (sg-0b0d1792df2a836a6)
- Step 5 adds IP to engineering (sg-0b0d1792df2a836a6)
- Result: Product access is restored

---

## Why IAM Permission Works But Issue Remains

✅ **IAM Permission**: Successfully added, no more `UnauthorizedOperation` errors
✅ **IP Revocation**: Working correctly - removes IPs as intended
❌ **Logic Bug**: Revoked access is immediately restored due to shared security groups

**Logs Prove This**:
```
[IP-REVOKE] Removed dmar@capsule.com IP 136.62.92.204 from instance i-0966d965518d2dba1
```
^ Revocation succeeded (no UnauthorizedOperation error)

But on next login, product is detected as needing revocation again, proving the IP was re-added.

---

## Solutions

### Option 1: Separate Security Groups Per Area ⭐ RECOMMENDED

**Change**: Ensure each area has its own security group for user IP whitelisting.

**Implementation**:
1. Create area-specific security groups when launching instances
2. Update existing instances to use area-specific groups
3. Portal logic remains unchanged

**Pros**:
- Cleanest solution
- Follows principle of least privilege
- Portal logic works as designed
- No code changes needed

**Cons**:
- Requires infrastructure changes
- Need to migrate existing instances

**Files to modify**:
- `terraform/envs/tier5/main.tf` - Instance launch logic
- Migration script to update existing instances

---

### Option 2: Deduplicate Security Groups in Portal Logic

**Change**: Modify portal to handle shared security groups correctly.

**Implementation**:
Track security groups that have been modified in the current whitelisting operation:
```python
modified_sgs = set()

# Revoke step:
for instance in lost_access:
    sg_id = get_sg_for_instance(instance)
    if sg_id not in modified_sgs:
        remove_ip_from_sg(sg_id, user_ip)
        modified_sgs.add(sg_id)

# Add step:
for instance in should_have_access:
    sg_id = get_sg_for_instance(instance)
    if sg_id not in modified_sgs:
        add_ip_to_sg(sg_id, user_ip)
        modified_sgs.add(sg_id)
```

**Pros**:
- No infrastructure changes
- Works with existing setup

**Cons**:
- Doesn't solve the fundamental security issue (users get access to all instances sharing a SG)
- Complex logic
- Still violates least privilege

**Verdict**: Not recommended - papers over the real issue.

---

### Option 3: Instance-Specific Security Groups

**Change**: Create a unique security group for each instance at launch time.

**Implementation**:
- Modify instance launch to create `vibecode-instance-{instance_id}` security group
- Attach both base security group + instance-specific group
- Add IP rules only to instance-specific group

**Pros**:
- Perfect granularity
- Supports complex access patterns

**Cons**:
- Many security groups to manage
- Hits AWS limits faster (default: 2,500 SGs per region)

---

## Recommended Action Plan

### Phase 1: Immediate Fix (Infrastructure)

1. **Audit all instances** to identify which ones share security groups:
   ```bash
   aws ec2 describe-instances \
     --filters "Name=tag:VibeCodeArea,Values=*" \
     --query 'Reservations[].Instances[].[Tags[?Key==`VibeCodeArea`].Value|[0], InstanceId, SecurityGroups[0].GroupId]' \
     --output table
   ```

2. **Create area-specific security groups** for each area that doesn't have one:
   ```bash
   aws ec2 create-security-group \
     --group-name vibecode-area-product \
     --description "Security group for product area instances" \
     --vpc-id vpc-XXXXXXXX
   ```

3. **Migrate instances** to use area-specific security groups:
   ```bash
   aws ec2 modify-instance-attribute \
     --instance-id i-XXXXXXXXX \
     --groups sg-XXXXXXXXX sg-YYYYYYY
   ```

4. **Test IP whitelisting** with dmar@capsule.com after migration

### Phase 2: Prevent Future Issues (Terraform)

5. **Update Terraform** instance launch logic to assign area-specific security groups:
   - Add security group lookup/creation by area
   - Ensure new instances use correct group

6. **Add validation** to prevent shared security groups across areas:
   - Terraform validation rule
   - Portal startup check

### Phase 3: Monitoring

7. **Add logging** to detect shared security group issues:
   ```python
   sg_to_instances = {}
   for instance in all_instances:
       sg = instance.security_group
       if sg in sg_to_instances and sg_to_instances[sg] != instance.area:
           log_warning(f"SG {sg} shared by areas: {sg_to_instances[sg]} and {instance.area}")
   ```

---

## Testing Checklist

After implementing fixes:

- [ ] User with single area group only has access to that area
- [ ] User removed from area group loses access on next login
- [ ] IP revocation logs show success without re-revoking same instance
- [ ] No `UnauthorizedOperation` errors in logs
- [ ] Security groups don't accumulate orphaned IP rules
- [ ] Each area has its own security group
- [ ] No instances share security groups across areas

---

## Files Analyzed

| File | Purpose | Issues Found |
|------|---------|--------------|
| `/opt/employee-portal/app.py:999` | `get_instances_user_is_whitelisted_on()` | Returns duplicates when SGs shared |
| `/opt/employee-portal/app.py:1063` | `whitelist_user_ip_on_instances()` | Revoke/add conflict with shared SGs |
| `/opt/employee-portal/app.py:729` | `get_instance_security_groups()` | Working correctly |
| `main.tf:536` | IAM role policy | ✅ Fixed - has RevokeSecurityGroupIngress |

---

## Conclusion

**IAM Permission Fix**: ✅ Successfully deployed and working
**IP Revocation Feature**: ✅ Technically working (no permission errors)
**Shared Security Group Bug**: ❌ Critical issue preventing correct behavior

**Next Step**: Implement Option 1 (separate security groups per area) to resolve the root cause.

---

## Appendix: Commands Used for Debugging

### Check user groups
```bash
aws cognito-idp admin-list-groups-for-user \
  --user-pool-id us-west-2_WePThH2J8 \
  --username dmar@capsule.com \
  --region us-west-2
```

### Audit security group rules
```bash
aws ec2 describe-security-groups \
  --group-ids sg-XXXXXXXXX \
  --query 'SecurityGroups[0].IpPermissions[].IpRanges[]' \
  --output table
```

### Check portal logs
```bash
ssh ubuntu@54.202.154.151 \
  "sudo journalctl -u employee-portal --since '10 minutes ago' | grep -E 'dmar|IP-REVOKE'"
```

### Verify IAM permission
```bash
aws iam get-role-policy \
  --role-name employee-portal-ec2-role \
  --policy-name employee-portal-ec2-cognito-policy \
  --query 'PolicyDocument.Statement[].Action[]?' | grep Revoke
```
