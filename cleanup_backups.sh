#!/bin/bash
# Clean up old backup files on portal server

echo "Cleaning up backup files on portal server..."

ssh -i ~/.ssh/david-capsule-vibecode-2026-01-17.pem ubuntu@54.202.154.151 << 'REMOTE'
# Keep the 2 most recent backups, delete older ones
cd /opt/employee-portal

# List backups
echo "Current backups:"
ls -lh *.backup* 2>/dev/null | wc -l
ls -lh templates/*.backup* 2>/dev/null | wc -l

# Keep only backups from today, remove older ones
echo "Removing old backups (keeping only today's)..."
sudo find /opt/employee-portal -name "*.backup*" -mtime +1 -delete 2>/dev/null || true
sudo find /opt/employee-portal/templates -name "*.backup*" -mtime +1 -delete 2>/dev/null || true

echo "Remaining backups:"
ls -lh *.backup* 2>/dev/null | wc -l
ls -lh templates/*.backup* 2>/dev/null | wc -l
REMOTE

echo "Cleanup complete!"
