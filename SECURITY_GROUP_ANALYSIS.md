# Security Group Analysis - IP Whitelisting Architecture Issue

## Instance to Security Group Mapping

| Instance Name | Area | Instance ID | Security Groups Attached |
|--------------|------|-------------|--------------------------|
| **2026-01-jan-28-vibecode-instance-01** | finance | i-0a79e8c95b2666cbf | • sg-06b525854143eb245 (vibecode-launched-instances) |
| **eric-john-ec2-us-west-2-claude-code** | hr | i-06883f2837f77f365 | • sg-0d6bbadbbd290b320 (launch-wizard-7) |
| **vibe-code-david-mar-server** | engineering | i-0d1e3b59f57974076 | • sg-0b0d1792df2a836a6 (vibecode-launched-instances)<br>• sg-0d485b4ffe8c8f886 (launch-wizard-8) |
| **vibe-code-john-eric-server** | product | i-0966d965518d2dba1 | • sg-0b0d1792df2a836a6 (vibecode-launched-instances)<br>• sg-0d6bbadbbd290b320 (launch-wizard-7) |

## Security Group Details (Ports 80/443 Only)

### sg-06b525854143eb245 (vibecode-launched-instances)
**Used by:** Finance instance ONLY

| Port | Whitelisted IPs |
|------|-----------------|
| 80 | • 136.62.92.204/32 (dmar@capsule.com) |
| 443 | • 136.62.92.204/32 (dmar@capsule.com) |

✅ **Status:** Unique to finance area

---

### sg-0b0d1792df2a836a6 (vibecode-launched-instances)
**Used by:** Engineering AND Product instances (SHARED!)

| Port | Whitelisted IPs |
|------|-----------------|
| 80 | • 136.62.92.204/32 (dmar@capsule.com) |
| 443 | • 136.62.92.204/32 (dmar@capsule.com) |

🚨 **CRITICAL ISSUE:** This security group is attached to BOTH:
- engineering instance (i-0d1e3b59f57974076)
- product instance (i-0966d965518d2dba1)

**Impact:** Any IP whitelisted for engineering is also whitelisted for product, and vice versa!

---

### sg-0d6bbadbbd290b320 (launch-wizard-7)
**Used by:** HR instance AND Product instance (SHARED!)

| Port | Whitelisted IPs |
|------|-----------------|
| 80 | • 0.0.0.0/0 (open to internet) |
| 443 | *(No rules configured)* |

⚠️ **Issue:** This security group is attached to BOTH:
- hr instance (i-06883f2837f77f365)
- product instance (i-0966d965518d2dba1)

**Note:** The IP whitelisting code doesn't modify this SG (it only looks for "vibecode-launched-instances"), so this doesn't affect the whitelisting feature.

---

### sg-0d485b4ffe8c8f886 (launch-wizard-8)
**Used by:** Engineering instance only

*(No port 80/443 rules with specific IPs - likely only has SSH or other ports)*

---

## The Security Architecture Problem

### Current State Visualization

```
Finance Area:
  i-0a79e8c95b2666cbf → [sg-06b525854143eb245] ← IP whitelist applied ✅
                         └─ Unique to finance ✅

Engineering Area:
  i-0d1e3b59f57974076 → [sg-0b0d1792df2a836a6] ← IP whitelist applied ✅
                         │                        └─ SHARED with Product! 🚨
                         └─ [sg-0d485b4ffe8c8f886]

Product Area:
  i-0966d965518d2dba1 → [sg-0b0d1792df2a836a6] ← IP whitelist applied ✅
                         │                        └─ SHARED with Engineering! 🚨
                         └─ [sg-0d6bbadbbd290b320]
                                                   └─ SHARED with HR (but not used for whitelisting)

HR Area:
  i-06883f2837f77f365 → [sg-0d6bbadbbd290b320] ← NOT processed (wrong SG name) ❌
```

### What Happens When Users Login

**Scenario 1: User ONLY in "engineering" group logs in**
- Code finds engineering instance (i-0d1e3b59f57974076)
- Code adds user's IP to sg-0b0d1792df2a836a6
- ✅ User can now access engineering instance
- 🚨 **User can ALSO access product instance** (same SG!)

**Scenario 2: User ONLY in "product" group logs in**
- Code finds product instance (i-0966d965518d2dba1)
- Code adds user's IP to sg-0b0d1792df2a836a6
- ✅ User can now access product instance
- 🚨 **User can ALSO access engineering instance** (same SG!)

**Scenario 3: User ONLY in "finance" group logs in**
- Code finds finance instance (i-0a79e8c95b2666cbf)
- Code adds user's IP to sg-06b525854143eb245
- ✅ User can now access finance instance
- ✅ User CANNOT access other instances (unique SG)

**Scenario 4: User ONLY in "hr" group logs in**
- Code finds hr instance (i-06883f2837f77f365)
- Code looks for "vibecode-launched-instances" SG on instance
- ❌ Not found (instance has "launch-wizard-7")
- ❌ User's IP is NOT whitelisted anywhere

## Summary Table: Cross-Instance Access

| If user is in group: | Gets access to instances: | Should have access to: | Problem? |
|---------------------|---------------------------|------------------------|----------|
| finance | Finance | Finance | ✅ Correct |
| engineering | Engineering + Product | Engineering | 🚨 **LEAKS Product access** |
| product | Engineering + Product | Product | 🚨 **LEAKS Engineering access** |
| hr | None | HR | ❌ **NO ACCESS** (SG mismatch) |

## Root Cause

**The code assumes each area has a unique security group, but:**
1. Engineering and Product share `sg-0b0d1792df2a836a6`
2. AWS security groups work at the **network level**, not the instance level
3. When you add an IP rule to a security group, it applies to **ALL instances** using that security group

**This creates unintended cross-area access.**

## Why It Happened

Looking at the security group IDs, there are TWO different `vibecode-launched-instances` security groups:
- `sg-06b525854143eb245` (finance)
- `sg-0b0d1792df2a836a6` (engineering + product)

This suggests:
- Finance instance was created in a different VPC or with the launch feature (created new SG)
- Engineering and Product instances were created manually and assigned the same existing SG

## Verification: Are These Actually Different Security Groups?

Let me verify these are truly different SGs with the same name...

```bash
aws ec2 describe-security-groups \
  --group-ids sg-06b525854143eb245 sg-0b0d1792df2a836a6 \
  --query 'SecurityGroups[*].[GroupId,GroupName,VpcId]' \
  --region us-west-2
```

## Recommendations

### Option 1: Create Area-Specific Security Groups (Recommended)

Create and attach unique security groups for each area:

```bash
# Create new security groups
aws ec2 create-security-group \
  --group-name vibecode-engineering-unique \
  --description "Engineering area instances only" \
  --vpc-id <vpc-id> \
  --region us-west-2

aws ec2 create-security-group \
  --group-name vibecode-product-unique \
  --description "Product area instances only" \
  --vpc-id <vpc-id> \
  --region us-west-2

# Update instances to use unique SGs
aws ec2 modify-instance-attribute \
  --instance-id i-0d1e3b59f57974076 \
  --groups sg-<new-engineering-sg> sg-0d485b4ffe8c8f886

aws ec2 modify-instance-attribute \
  --instance-id i-0966d965518d2dba1 \
  --groups sg-<new-product-sg> sg-0d6bbadbbd290b320
```

### Option 2: Use Security Group Tags

Tag each security group with its intended area:

```python
# Modified whitelisting logic
for sg in security_groups:
    tags = get_security_group_tags(sg['GroupId'])
    if tags.get('VibeCodeArea') == area:
        sg_id = sg['GroupId']
        break
```

### Option 3: Document and Accept the Risk

If Engineering and Product teams should have mutual access, document this as intentional rather than a bug.

## Testing Needed

To verify this is actually a problem (not just theoretical):

1. Create a test user ONLY in "engineering" group (not in "product")
2. Have them log in
3. Check if they can access the product instance
4. Expected: They SHOULD NOT be able to (but currently CAN due to shared SG)
