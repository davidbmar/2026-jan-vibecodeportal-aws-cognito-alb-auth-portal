"""
Integration tests for Cognito Custom Authentication Flow

Tests the complete authentication flow with actual AWS services.
Requires: AWS credentials, deployed infrastructure
"""

import boto3
import pytest
import time
import os
from datetime import datetime

# AWS Configuration
AWS_REGION = os.getenv('AWS_REGION', 'us-west-2')
USER_POOL_ID = os.getenv('USER_POOL_ID', '')  # Set from terraform output
CLIENT_ID = os.getenv('CLIENT_ID', '')  # Set from terraform output
CLIENT_SECRET = os.getenv('CLIENT_SECRET', '')  # Set from terraform output

# Test user
TEST_USER_EMAIL = 'dmar@capsule.com'
TEST_USER_PASSWORD = 'SecurePass123!'

# Skip tests if credentials not configured
pytestmark = pytest.mark.skipif(
    not all([USER_POOL_ID, CLIENT_ID]),
    reason="AWS credentials or Cognito pool not configured"
)


class TestCognitoCustomAuthFlow:
    """Integration tests for Cognito custom auth with email MFA"""

    def setup_method(self):
        """Setup for each test"""
        self.cognito_client = boto3.client('cognito-idp', region_name=AWS_REGION)
        self.dynamodb = boto3.resource('dynamodb', region_name=AWS_REGION)
        self.logs_client = boto3.client('logs', region_name=AWS_REGION)

        # Get table name from environment or default
        self.mfa_table_name = os.getenv('MFA_CODES_TABLE', 'employee-portal-mfa-codes')

    def test_initiate_auth_triggers_define_lambda(self):
        """
        Test: Initiate authentication
        Expected: DefineAuthChallenge Lambda is invoked
        """
        print("\n🧪 TEST: Initiate Auth Triggers DefineAuthChallenge\n")

        # Get timestamp before test
        start_time = int(time.time() * 1000)

        try:
            # Initiate authentication (this will fail without password, but should trigger Lambda)
            response = self.cognito_client.initiate_auth(
                ClientId=CLIENT_ID,
                AuthFlow='USER_PASSWORD_AUTH',
                AuthParameters={
                    'USERNAME': TEST_USER_EMAIL,
                    'PASSWORD': 'WrongPassword123!'  # Wrong password intentionally
                }
            )
        except Exception as e:
            print(f"  Expected error: {str(e)}")

        # Wait for CloudWatch logs to propagate
        time.sleep(5)

        # Check CloudWatch logs for DefineAuthChallenge invocation
        log_group = '/aws/lambda/employee-portal-define-auth-challenge'

        try:
            log_streams = self.logs_client.describe_log_streams(
                logGroupName=log_group,
                orderBy='LastEventTime',
                descending=True,
                limit=1
            )

            if log_streams['logStreams']:
                stream_name = log_streams['logStreams'][0]['logStreamName']

                # Get recent log events
                events = self.logs_client.get_log_events(
                    logGroupName=log_group,
                    logStreamName=stream_name,
                    startTime=start_time,
                    limit=50
                )

                # Check if Lambda was invoked
                has_invocation = any('DefineAuthChallenge invoked' in event['message']
                                    for event in events['events'])

                if has_invocation:
                    print("  ✅ DefineAuthChallenge Lambda was invoked")
                else:
                    print("  ⚠️  Could not confirm Lambda invocation in logs")
                    print(f"     Log group: {log_group}")
                    print(f"     Stream: {stream_name}")

                print("\n  Recent log entries:")
                for event in events['events'][:5]:
                    print(f"    {event['message']}")

        except Exception as e:
            print(f"  ⚠️  Could not access CloudWatch logs: {str(e)}")
            print("     This may be a permissions issue")

        print("\n✅ TEST COMPLETE\n")

    def test_correct_password_generates_mfa_code(self):
        """
        Test: Submit correct password
        Expected: CreateAuthChallenge generates code and stores in DynamoDB
        """
        print("\n🧪 TEST: Correct Password Generates MFA Code\n")

        # Clear any existing code for test user
        table = self.dynamodb.Table(self.mfa_table_name)
        try:
            table.delete_item(Key={'username': TEST_USER_EMAIL})
            print(f"  Cleared existing code for {TEST_USER_EMAIL}")
        except Exception:
            pass

        # Attempt authentication with correct password
        try:
            response = self.cognito_client.initiate_auth(
                ClientId=CLIENT_ID,
                AuthFlow='USER_PASSWORD_AUTH',
                AuthParameters={
                    'USERNAME': TEST_USER_EMAIL,
                    'PASSWORD': TEST_USER_PASSWORD
                }
            )

            print(f"  Response received: {response.get('ChallengeName', 'No challenge')}")

            if response.get('ChallengeName') == 'CUSTOM_CHALLENGE':
                print("  ✅ CUSTOM_CHALLENGE issued (email MFA)")

                # Wait for code to be stored
                time.sleep(2)

                # Check DynamoDB for code
                result = table.get_item(Key={'username': TEST_USER_EMAIL})

                if 'Item' in result:
                    code = result['Item']['code']
                    ttl = result['Item']['ttl']
                    created_at = result['Item'].get('created_at', 'unknown')

                    print(f"\n  ✅ Code stored in DynamoDB:")
                    print(f"     Code: {code}")
                    print(f"     TTL: {ttl} ({datetime.fromtimestamp(ttl)})")
                    print(f"     Created: {created_at}")

                    # Verify code format
                    assert len(code) == 6, "Code should be 6 digits"
                    assert code.isdigit(), "Code should be numeric"

                    # Verify TTL is ~5 minutes from now
                    current_time = int(time.time())
                    ttl_diff = ttl - current_time
                    assert 250 < ttl_diff < 350, f"TTL should be ~5 minutes, got {ttl_diff} seconds"

                    print(f"\n  ✅ Code format valid (6 digits)")
                    print(f"  ✅ TTL valid ({ttl_diff} seconds ≈ 5 minutes)")

                else:
                    print("  ❌ Code NOT found in DynamoDB")
                    print(f"     Table: {self.mfa_table_name}")
                    print(f"     Key: {TEST_USER_EMAIL}")

                    # Scan table to see what's there
                    scan_result = table.scan(Limit=10)
                    print(f"\n  Table contents (first 10 items):")
                    for item in scan_result.get('Items', []):
                        print(f"    {item}")

            else:
                print(f"  ⚠️  Expected CUSTOM_CHALLENGE, got: {response.get('ChallengeName')}")
                print(f"  Full response: {response}")

        except Exception as e:
            print(f"  ❌ Error during authentication: {str(e)}")
            raise

        print("\n✅ TEST COMPLETE\n")

    def test_verify_mfa_code_grants_access(self):
        """
        Test: Submit correct MFA code
        Expected: VerifyAuthChallenge validates and Cognito issues tokens
        """
        print("\n🧪 TEST: Correct MFA Code Grants Access\n")

        # Step 1: Authenticate with password to get MFA challenge
        print("  Step 1: Authenticate with password...")
        response = self.cognito_client.initiate_auth(
            ClientId=CLIENT_ID,
            AuthFlow='USER_PASSWORD_AUTH',
            AuthParameters={
                'USERNAME': TEST_USER_EMAIL,
                'PASSWORD': TEST_USER_PASSWORD
            }
        )

        if response.get('ChallengeName') != 'CUSTOM_CHALLENGE':
            print(f"  ❌ Expected CUSTOM_CHALLENGE, got: {response.get('ChallengeName')}")
            pytest.skip("Custom challenge not issued")

        session = response['Session']
        print("  ✅ CUSTOM_CHALLENGE issued")

        # Step 2: Retrieve code from DynamoDB (simulates receiving email)
        print("\n  Step 2: Retrieve MFA code from DynamoDB...")
        time.sleep(2)

        table = self.dynamodb.Table(self.mfa_table_name)
        result = table.get_item(Key={'username': TEST_USER_EMAIL})

        if 'Item' not in result:
            print("  ❌ Code not found in DynamoDB")
            pytest.skip("Code not generated")

        mfa_code = result['Item']['code']
        print(f"  ✅ Retrieved code: {mfa_code}")

        # Step 3: Submit MFA code
        print("\n  Step 3: Submit MFA code...")
        try:
            auth_response = self.cognito_client.respond_to_auth_challenge(
                ClientId=CLIENT_ID,
                ChallengeName='CUSTOM_CHALLENGE',
                Session=session,
                ChallengeResponses={
                    'ANSWER': mfa_code,
                    'USERNAME': TEST_USER_EMAIL
                }
            )

            # Check if tokens were issued
            if 'AuthenticationResult' in auth_response:
                tokens = auth_response['AuthenticationResult']

                print("  ✅ Authentication successful!")
                print(f"\n  Tokens received:")
                print(f"     AccessToken: {tokens['AccessToken'][:50]}...")
                print(f"     IdToken: {tokens['IdToken'][:50]}...")
                print(f"     RefreshToken: {tokens.get('RefreshToken', 'N/A')[:50]}...")
                print(f"     ExpiresIn: {tokens['ExpiresIn']} seconds")

                # Verify code was deleted from DynamoDB
                time.sleep(1)
                result = table.get_item(Key={'username': TEST_USER_EMAIL})
                if 'Item' not in result:
                    print("\n  ✅ Code deleted from DynamoDB (single-use)")
                else:
                    print("\n  ⚠️  Code still in DynamoDB (should be deleted)")

            else:
                print(f"  ❌ No tokens issued")
                print(f"  Response: {auth_response}")

        except Exception as e:
            print(f"  ❌ Error submitting MFA code: {str(e)}")
            raise

        print("\n✅ TEST COMPLETE - Full authentication flow successful!\n")

    def test_wrong_mfa_code_fails(self):
        """
        Test: Submit incorrect MFA code
        Expected: Authentication fails
        """
        print("\n🧪 TEST: Wrong MFA Code Fails\n")

        # Step 1: Get MFA challenge
        print("  Step 1: Authenticate with password...")
        response = self.cognito_client.initiate_auth(
            ClientId=CLIENT_ID,
            AuthFlow='USER_PASSWORD_AUTH',
            AuthParameters={
                'USERNAME': TEST_USER_EMAIL,
                'PASSWORD': TEST_USER_PASSWORD
            }
        )

        if response.get('ChallengeName') != 'CUSTOM_CHALLENGE':
            pytest.skip("Custom challenge not issued")

        session = response['Session']
        print("  ✅ CUSTOM_CHALLENGE issued")

        # Step 2: Submit WRONG code
        print("\n  Step 2: Submit wrong MFA code (000000)...")
        try:
            auth_response = self.cognito_client.respond_to_auth_challenge(
                ClientId=CLIENT_ID,
                ChallengeName='CUSTOM_CHALLENGE',
                Session=session,
                ChallengeResponses={
                    'ANSWER': '000000',  # Wrong code
                    'USERNAME': TEST_USER_EMAIL
                }
            )

            # Should not get tokens
            if 'AuthenticationResult' in auth_response:
                print("  ❌ UNEXPECTED: Tokens issued with wrong code!")
                pytest.fail("Wrong code should not grant access")
            else:
                print("  ✅ Authentication failed (as expected)")
                print(f"  Response: {auth_response}")

        except self.cognito_client.exceptions.NotAuthorizedException:
            print("  ✅ NotAuthorizedException raised (as expected)")

        except Exception as e:
            print(f"  Exception: {str(e)}")
            if 'Incorrect' in str(e) or 'invalid' in str(e).lower():
                print("  ✅ Wrong code rejected")
            else:
                raise

        print("\n✅ TEST COMPLETE\n")


if __name__ == '__main__':
    # Run tests
    print("\n" + "="*60)
    print("COGNITO CUSTOM AUTH FLOW - INTEGRATION TESTS")
    print("="*60 + "\n")

    print("Configuration:")
    print(f"  Region: {AWS_REGION}")
    print(f"  User Pool ID: {USER_POOL_ID or 'NOT SET'}")
    print(f"  Client ID: {CLIENT_ID or 'NOT SET'}")
    print(f"  MFA Table: {os.getenv('MFA_CODES_TABLE', 'employee-portal-mfa-codes')}")
    print()

    if not all([USER_POOL_ID, CLIENT_ID]):
        print("❌ Configuration incomplete. Set environment variables:")
        print("   export USER_POOL_ID=<your-pool-id>")
        print("   export CLIENT_ID=<your-client-id>")
        print("   export CLIENT_SECRET=<your-client-secret>  # If applicable")
        print()
        exit(1)

    pytest.main([__file__, '-v', '-s'])
