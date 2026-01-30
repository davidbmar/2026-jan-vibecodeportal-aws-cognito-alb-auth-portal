#!/bin/bash

# Push IP Whitelisting Implementation to GitHub
# This script helps you push the committed changes to GitHub

cd /home/ubuntu/cognito_alb_ec2

echo "================================================"
echo "PUSH IP WHITELISTING TO GITHUB"
echo "================================================"
echo ""

# Show what will be pushed
echo "Commits ready to push (22 commits):"
echo "-----------------------------------"
git log --oneline origin/main..main 2>/dev/null | head -10

echo ""
echo "Latest commit:"
git log -1 --format="%h - %s"

echo ""
echo "Files changed in latest commit:"
git show --stat --oneline HEAD | tail -10

echo ""
echo "================================================"
echo "READY TO PUSH"
echo "================================================"
echo ""
echo "To push these changes to GitHub, run ONE of these:"
echo ""
echo "OPTION 1: HTTPS (easiest, one-time)"
echo "  git push https://YOUR_TOKEN@github.com/davidbmar/2026-jan-vibecodeportal-aws-cognito-alb-auth-portal.git main"
echo ""
echo "OPTION 2: Standard push (will prompt for credentials)"
echo "  git push origin main"
echo ""
echo "OPTION 3: SSH (recommended for permanent setup)"
echo "  # First, generate SSH key:"
echo "  ssh-keygen -t ed25519 -C 'your_email@example.com'"
echo "  # Then add to GitHub and run:"
echo "  git remote set-url origin git@github.com:davidbmar/2026-jan-vibecodeportal-aws-cognito-alb-auth-portal.git"
echo "  git push origin main"
echo ""
echo "================================================"
echo ""
echo "After pushing, verify on GitHub:"
echo "https://github.com/davidbmar/2026-jan-vibecodeportal-aws-cognito-alb-auth-portal/commits/main"
echo ""
