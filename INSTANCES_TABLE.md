# EC2 Instances Overview

**Region:** us-west-2
**Generated:** 2026-01-29

## All Instances

| Name | Instance ID | Area | State | Type | Public IP | Security Group | SG ID | IP Whitelist Applied? |
|------|-------------|------|-------|------|-----------|----------------|-------|----------------------|
| 2026-01-jan-28-vibecode-instance-01 | i-0a79e8c95b2666cbf | finance | running | t3.micro | 18.246.242.120 | vibecode-launched-instances | sg-06b525854143eb245 | ✅ YES |
| eric-john-ec2-us-west-2-claude-code | i-06883f2837f77f365 | hr | running | t4g.medium | 16.148.76.153 | launch-wizard-7 | sg-0d6bbadbbd290b320 | ❌ NO (wrong SG) |
| vibe-code-david-mar-server | i-0d1e3b59f57974076 | engineering | running | m7i.large | 16.148.110.90 | vibecode-launched-instances | sg-0b0d1792df2a836a6 | ✅ YES |
| vibe-code-john-eric-server | i-0966d965518d2dba1 | product | running | m7i.xlarge | 44.244.76.51 | vibecode-launched-instances | sg-0b0d1792df2a836a6 | ✅ YES |
| employee-portal-portal | i-01ebe3bbad23c0efc | (portal) | running | t3.small | 54.202.154.151 | employee-portal-ec2-sg | sg-0b8f050ce3b2a783b | N/A (portal) |

## Summary

**Total Instances:** 5
- **Area-Specific (with VibeCodeArea tag):** 4
  - Finance: 1
  - HR: 1
  - Engineering: 1
  - Product: 1
- **Infrastructure (Portal):** 1

**IP Whitelisting Status:**
- ✅ **Working:** 3 instances (finance, engineering, product)
- ❌ **Excluded:** 1 instance (HR - uses launch-wizard-7 instead of vibecode-launched-instances)
- ⚪ **N/A:** 1 instance (employee portal)

## Notes

1. **HR Instance Issue:** The HR instance uses security group "launch-wizard-7" instead of "vibecode-launched-instances", so it's excluded from the automated IP whitelisting system.

2. **IP Whitelisting Logic:** The current code only processes instances with the `vibecode-launched-instances` security group attached.

3. **Multiple Security Groups:** An instance can have multiple security groups. To fix the HR instance, you can attach the `vibecode-launched-instances` security group in addition to its current `launch-wizard-7` group.

## Security Group Mapping

| Security Group Name | SG ID | Used By | Ports 80/443 Whitelisted? |
|---------------------|-------|---------|---------------------------|
| vibecode-launched-instances | sg-06b525854143eb245 | Finance | ✅ YES |
| vibecode-launched-instances | sg-0b0d1792df2a836a6 | Engineering, Product | ✅ YES |
| launch-wizard-7 | sg-0d6bbadbbd290b320 | HR | ❌ NO |
| employee-portal-ec2-sg | sg-0b8f050ce3b2a783b | Portal | N/A |

## Current Whitelisted IPs (136.62.92.204/32 - dmar@capsule.com)

| Security Group | Port 80 | Port 443 | Notes |
|----------------|---------|----------|-------|
| sg-06b525854143eb245 (finance) | ✅ | ✅ | Working |
| sg-0b0d1792df2a836a6 (eng/product) | ✅ | ✅ | Working |
| sg-0d6bbadbbd290b320 (HR) | ⚪ 0.0.0.0/0 | ❌ Not configured | Port 80 open to internet, Port 443 not configured |
