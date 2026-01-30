"""
VerifyAuthChallenge Lambda
Validates the MFA code entered by the user.

This Lambda:
1. Compares user-entered code with stored code
2. Deletes code from DynamoDB if correct (prevent reuse)
3. Returns validation result to Cognito
"""

import os
import boto3


def lambda_handler(event, context):
    """
    Verify the MFA code entered by the user.

    Args:
        event: Cognito event containing challenge answer
        context: Lambda context (unused)

    Returns:
        Modified event with answerCorrect set
    """
    print(f"VerifyAuthChallenge invoked")

    # Get the expected code (from CreateAuthChallenge)
    expected_code = event['request']['privateChallengeParameters'].get('code')

    # Get the user's answer
    user_code = event['request']['challengeAnswer']

    # Get user email for logging
    email = event['request']['userAttributes'].get('email', 'unknown')

    print(f"Verifying code for user: {email}")
    print(f"User entered: '{user_code}' (type: {type(user_code)})")
    print(f"Expected: '{expected_code}' (type: {type(expected_code)})")
    print(f"User code stripped: '{user_code.strip() if user_code else None}'")
    print(f"Expected code stripped: '{expected_code.strip() if expected_code else None}'")

    # Validate code
    if user_code and expected_code and user_code.strip() == expected_code.strip():
        print("Code is CORRECT - Match found!")
        print(f"Comparison: '{user_code.strip()}' == '{expected_code.strip()}'")
        event['response']['answerCorrect'] = True

        # Delete code from DynamoDB to prevent reuse
        try:
            dynamodb = boto3.resource('dynamodb')
            table_name = os.environ['MFA_CODES_TABLE']
            table = dynamodb.Table(table_name)

            table.delete_item(
                Key={'username': email}
            )
            print(f"Deleted code from DynamoDB for {email}")

        except Exception as e:
            print(f"WARNING: Could not delete code from DynamoDB: {str(e)}")
            # Don't fail authentication if deletion fails

    else:
        print("Code is INCORRECT - No match")
        print(f"User provided: {bool(user_code)}, Expected exists: {bool(expected_code)}")
        print(f"String comparison: '{user_code.strip() if user_code else 'None'}' != '{expected_code.strip() if expected_code else 'None'}'")
        event['response']['answerCorrect'] = False

    print(f"Verification result: {event['response']['answerCorrect']}")
    return event
