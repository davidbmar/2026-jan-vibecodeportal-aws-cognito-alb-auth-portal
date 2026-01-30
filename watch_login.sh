#!/bin/bash
echo "Watching for login events..."
echo "Please login now as dmar@capsule.com"
echo "Press Ctrl+C to stop watching"
echo ""
ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 \
  'sudo journalctl -u employee-portal -f | grep --line-buffered "IP-WHITELIST\|Successful login\|Error adding IP"'
