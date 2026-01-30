# Clear Security Group Table - IP Whitelisting Analysis

## Instance Configuration

| Instance Name | Area | Instance ID | Security Groups (SG ID) | VPC |
|--------------|------|-------------|-------------------------|-----|
| **2026-01-jan-28-vibecode-instance-01** | finance | i-0a79e8c95b2666cbf | • vibecode-launched-instances<br>&nbsp;&nbsp;(sg-06b525854143eb245) | vpc-0b2126f3d25758cfa |
| **vibe-code-david-mar-server** | engineering | i-0d1e3b59f57974076 | • vibecode-launched-instances<br>&nbsp;&nbsp;(sg-0b0d1792df2a836a6)<br>• launch-wizard-8<br>&nbsp;&nbsp;(sg-0d485b4ffe8c8f886) | vpc-c8d44bb0 |
| **vibe-code-john-eric-server** | product | i-0966d965518d2dba1 | • vibecode-launched-instances<br>&nbsp;&nbsp;(sg-0b0d1792df2a836a6)<br>• launch-wizard-7<br>&nbsp;&nbsp;(sg-0d6bbadbbd290b320) | vpc-c8d44bb0 |
| **eric-john-ec2-us-west-2-claude-code** | hr | i-06883f2837f77f365 | • launch-wizard-7<br>&nbsp;&nbsp;(sg-0d6bbadbbd290b320) | vpc-c8d44bb0 |

## Security Group Details

### sg-06b525854143eb245 (vibecode-launched-instances) - Finance VPC

**VPC:** vpc-0b2126f3d25758cfa
**Used by:** Finance instance ONLY

| Port | Whitelisted IP | User | Status |
|------|---------------|------|--------|
| 80 | 136.62.92.204/32 | dmar@capsule.com | ✅ Working |
| 443 | 136.62.92.204/32 | dmar@capsule.com | ✅ Working |

**Access Result:** Finance users get access to Finance instance only ✅

---

### sg-0b0d1792df2a836a6 (vibecode-launched-instances) - Engineering/Product VPC

**VPC:** vpc-c8d44bb0
**Used by:** Engineering instance AND Product instance (SHARED!)

| Port | Whitelisted IP | User | Status |
|------|---------------|------|--------|
| 80 | 136.62.92.204/32 | dmar@capsule.com | ✅ Working |
| 443 | 136.62.92.204/32 | dmar@capsule.com | ✅ Working |

🚨 **CRITICAL ISSUE:** This same security group is attached to:
- i-0d1e3b59f57974076 (engineering)
- i-0966d965518d2dba1 (product)

**Access Result:**
- Engineering users get access to BOTH Engineering AND Product instances 🚨
- Product users get access to BOTH Product AND Engineering instances 🚨

---

### sg-0d6bbadbbd290b320 (launch-wizard-7)

**VPC:** vpc-c8d44bb0
**Used by:** HR instance AND Product instance

| Port | Configuration | Status |
|------|--------------|--------|
| 80 | 0.0.0.0/0 (open) | ⚪ Open to internet |
| 443 | Not configured | ❌ No rules |

**Note:** IP whitelisting code doesn't process this SG (looks for "vibecode-launched-instances" only)

---

## The Problem Explained Simply

### What's Supposed to Happen

```
User in "engineering" group logs in
  → IP gets added to engineering instance security group
  → User can access engineering instance
  → User CANNOT access product instance
```

### What Actually Happens

```
User in "engineering" group logs in
  → IP gets added to sg-0b0d1792df2a836a6
  → sg-0b0d1792df2a836a6 is attached to:
      - Engineering instance ✅
      - Product instance 🚨
  → User can access BOTH engineering AND product instances
```

## Visual Diagram

```
┌─────────────────────────────────────────────┐
│ Finance VPC (vpc-0b2126f3d25758cfa)         │
│                                             │
│  Finance Instance                           │
│  i-0a79e8c95b2666cbf                       │
│         │                                   │
│         └── sg-06b525854143eb245            │
│             (vibecode-launched-instances)   │
│             IP: 136.62.92.204 ✅           │
│                                             │
└─────────────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│ Engineering/Product VPC (vpc-c8d44bb0)      │
│                                             │
│  Engineering Instance    Product Instance   │
│  i-0d1e3b59f57974076    i-0966d965518d2dba1│
│         │                        │          │
│         └────────┬────────────────┘          │
│                  │                           │
│         sg-0b0d1792df2a836a6                │
│         (vibecode-launched-instances)        │
│         IP: 136.62.92.204                   │
│         🚨 SHARED BETWEEN BOTH! 🚨           │
│                                             │
│  HR Instance                                │
│  i-06883f2837f77f365                       │
│         │                                   │
│         └── sg-0d6bbadbbd290b320            │
│             (launch-wizard-7)               │
│             NOT processed by whitelist ❌   │
│                                             │
└─────────────────────────────────────────────┘
```

## Summary Table: Who Can Access What

| User's Group | Should Access | Actually Accesses | Problem? |
|-------------|---------------|-------------------|----------|
| finance only | Finance | Finance | ✅ Correct |
| engineering only | Engineering | Engineering + Product | 🚨 **Unauthorized Product access** |
| product only | Product | Engineering + Product | 🚨 **Unauthorized Engineering access** |
| hr only | HR | Nothing | ❌ **No access** (SG name mismatch) |

## Why This Happened

1. **Finance instance** was created in its own VPC (vpc-0b2126f3d25758cfa) with its own security group
2. **Engineering and Product instances** were created in a different VPC (vpc-c8d44bb0) and assigned the SAME security group (sg-0b0d1792df2a836a6)
3. **The IP whitelisting code doesn't check which instance uses which security group** - it just finds the first security group named "vibecode-launched-instances" and adds the IP to it
4. **AWS security groups apply to ALL instances** that have them attached

## The Fix

**You need each area to have its own unique security group:**

```bash
# Option 1: Create new SG for product and switch it over
aws ec2 create-security-group \
  --group-name vibecode-product-unique \
  --description "Product area instances only" \
  --vpc-id vpc-c8d44bb0 \
  --region us-west-2

# Attach to product instance (keep other SGs too)
aws ec2 modify-instance-attribute \
  --instance-id i-0966d965518d2dba1 \
  --groups sg-<new-product-sg> sg-0d6bbadbbd290b320
```

**OR** accept that Engineering and Product users have mutual access and document it.

## Test to Confirm

1. Create a test user who is ONLY in the "engineering" group (not "product")
2. Have them log in to trigger IP whitelisting
3. Try to access the product instance at 44.244.76.51
4. **Expected:** Should be blocked ❌
5. **Actual:** Will work because of shared SG 🚨
