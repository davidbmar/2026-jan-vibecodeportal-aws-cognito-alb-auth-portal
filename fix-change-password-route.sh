#!/bin/bash
# Fix the /logout-and-reset route bug
# This script deploys the fix to the running EC2 instance

set -e

echo "🔧 Fixing /logout-and-reset route..."
echo ""
echo "The bug: Route tries to call Cognito logout which causes OAuth redirect_uri error"
echo "The fix: Redirect directly to /password-reset (password reset already handles security)"
echo ""

# Check if terraform is available
if command -v terraform &> /dev/null; then
    echo "✅ Terraform found"

    cd terraform/envs/tier5

    echo ""
    echo "📋 Terraform plan (checking what will change):"
    terraform plan

    echo ""
    read -p "Apply this fix? (yes/no): " confirm

    if [ "$confirm" = "yes" ]; then
        echo ""
        echo "🚀 Applying terraform changes..."
        terraform apply -auto-approve

        echo ""
        echo "✅ Fix deployed!"
        echo ""
        echo "📝 What changed:"
        echo "   - /logout-and-reset now redirects directly to /password-reset"
        echo "   - No more OAuth logout (avoids redirect_uri error)"
        echo "   - Password reset flow handles security via email verification"
        echo ""
        echo "🧪 Run tests to verify:"
        echo "   cd /home/ubuntu/cognito_alb_ec2/tests/playwright"
        echo "   npm run test:password"
        echo "   npm test tests/change-password.spec.js"
    else
        echo "❌ Deployment cancelled"
    fi
else
    echo "⚠️  Terraform not found"
    echo ""
    echo "Manual deployment steps:"
    echo "1. The fix has been applied to: terraform/envs/tier5/user_data.sh"
    echo "2. Deploy using one of these methods:"
    echo "   a. Run: cd terraform/envs/tier5 && terraform apply"
    echo "   b. Run: ./deploy_with_role.sh"
    echo "   c. Use AWS Console to replace EC2 instance user data and recreate"
    echo ""
    echo "3. After deployment, verify fix:"
    echo "   - Visit: https://portal.capsule-playground.com/settings"
    echo "   - Click: 🔑 CHANGE PASSWORD"
    echo "   - Should redirect to: /password-reset (not show OAuth error)"
fi
