"""
CreateAuthChallenge Lambda
Generates MFA code and sends it via email using SES.

This Lambda:
1. Generates a random 6-digit code
2. Stores it in DynamoDB with 5-minute TTL
3. Sends email via SES
4. Returns challenge parameters to Cognito
"""

import os
import random
import boto3
from datetime import datetime, timedelta, timezone


def lambda_handler(event, context):
    """
    Generate MFA code and send via email.

    Args:
        event: Cognito event containing user attributes
        context: Lambda context (unused)

    Returns:
        Modified event with challenge parameters
    """
    print(f"CreateAuthChallenge invoked for user: {event['request']['userAttributes'].get('email')}")

    # Only generate challenge for CUSTOM_CHALLENGE
    if event['request']['challengeName'] != 'CUSTOM_CHALLENGE':
        print(f"Skipping - not CUSTOM_CHALLENGE: {event['request']['challengeName']}")
        return event

    # Get user email
    email = event['request']['userAttributes']['email']

    # Generate 6-digit code
    code = str(random.randint(100000, 999999))
    print(f"Generated MFA code: {code} for {email}")

    # Store in DynamoDB with 5-minute TTL
    try:
        dynamodb = boto3.resource('dynamodb')
        table_name = os.environ['MFA_CODES_TABLE']
        table = dynamodb.Table(table_name)

        # Calculate expiry timestamp (5 minutes from now) - use UTC
        expiry_time = datetime.now(timezone.utc) + timedelta(minutes=5)
        ttl = int(expiry_time.timestamp())

        table.put_item(
            Item={
                'username': email,
                'code': code,
                'ttl': ttl,
                'created_at': datetime.now(timezone.utc).isoformat()
            }
        )
        print(f"Stored code in DynamoDB (TTL: {ttl})")

    except Exception as e:
        print(f"ERROR storing code in DynamoDB: {str(e)}")
        raise

    # Send email via SES
    try:
        ses = boto3.client('ses', region_name='us-west-2')
        from_email = os.environ.get('SES_FROM_EMAIL', 'noreply@capsule-playground.com')

        ses.send_email(
            Source=from_email,
            Destination={'ToAddresses': [email]},
            Message={
                'Subject': {'Data': 'Your CAPSULE Portal Login Code'},
                'Body': {
                    'Text': {
                        'Data': f'''Your verification code is: {code}

This code will expire in 5 minutes.

If you didn't request this code, please ignore this email.

- CAPSULE Security Team'''
                    }
                }
            }
        )
        print(f"Sent email to {email} via SES")

    except Exception as e:
        print(f"ERROR sending email via SES: {str(e)}")
        # Don't fail the Lambda if email fails - user can retry
        # In production, you might want to fail here or have a fallback

    # Set challenge parameters
    # Public: shown to client (don't include code!)
    event['response']['publicChallengeParameters'] = {
        'email': email,
        'challenge_type': 'EMAIL_MFA'
    }

    # Private: used for verification (includes code)
    event['response']['privateChallengeParameters'] = {
        'code': code
    }

    # Metadata for logging/debugging
    event['response']['challengeMetadata'] = 'EMAIL_MFA_CODE'

    print("CreateAuthChallenge complete")
    return event
