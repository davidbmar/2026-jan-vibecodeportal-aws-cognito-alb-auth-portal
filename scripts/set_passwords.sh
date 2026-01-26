#!/bin/bash

USER_POOL_ID="us-east-1_kF4pcrUVF"
PASSWORD="SecurePass123!"

echo "Setting passwords for all users..."

for USER in dmar@capsule.com jahn@capsule.com ahatcher@capsule.com peter@capsule.com sdedakia@capsule.com; do
  echo "Setting temporary password for $USER (must change on first login)..."
  aws cognito-idp admin-set-user-password --user-pool-id $USER_POOL_ID --username $USER --password "$PASSWORD" --region us-east-1
  if [ $? -eq 0 ]; then
    echo "✓ Temporary password set for $USER"
  else
    echo "✗ Failed to set password for $USER"
  fi
done

echo ""
echo "Done! All users must login with temporary password: $PASSWORD"
echo "Users will be forced to change their password on first login."
echo "Portal URL: https://portal.capsule-playground.com"
