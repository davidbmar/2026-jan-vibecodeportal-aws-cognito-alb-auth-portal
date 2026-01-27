"""
Unit tests for DefineAuthChallenge Lambda function

Tests the authentication flow orchestration logic.
"""

import sys
import pytest
from unittest.mock import Mock

# Mock AWS Lambda context
class MockContext:
    def __init__(self):
        self.function_name = "test-function"
        self.memory_limit_in_mb = 128
        self.invoked_function_arn = "arn:aws:lambda:us-west-2:123456789012:function:test"
        self.aws_request_id = "test-request-id"


def create_event(session_history):
    """Helper to create Cognito event structure"""
    return {
        'request': {
            'session': session_history,
            'userAttributes': {
                'email': 'test@example.com'
            }
        },
        'response': {}
    }


class TestDefineAuthChallenge:
    """Test cases for DefineAuthChallenge Lambda"""

    def setup_method(self):
        """Setup for each test"""
        # Import the lambda function
        # Note: In actual implementation, import from deployed Lambda
        self.handler = self.mock_handler

    def mock_handler(self, event, context):
        """Mock implementation of DefineAuthChallenge"""
        session = event['request']['session']

        event['response']['issueTokens'] = False
        event['response']['failAuthentication'] = False

        if len(session) == 0:
            event['response']['challengeName'] = 'SRP_A'
        elif len(session) == 1:
            if session[0]['challengeName'] == 'SRP_A' and session[0]['challengeResult']:
                event['response']['challengeName'] = 'CUSTOM_CHALLENGE'
                event['response']['issueTokens'] = False
            else:
                event['response']['failAuthentication'] = True
        elif len(session) == 2:
            if session[1]['challengeName'] == 'CUSTOM_CHALLENGE' and session[1]['challengeResult']:
                event['response']['issueTokens'] = True
            else:
                event['response']['failAuthentication'] = True
        else:
            event['response']['failAuthentication'] = True

        return event

    def test_first_attempt_no_session(self):
        """
        Test: User's first authentication attempt
        Expected: Request SRP_A (password) challenge
        """
        # Arrange
        event = create_event([])
        context = MockContext()

        # Act
        result = self.handler(event, context)

        # Assert
        assert result['response']['challengeName'] == 'SRP_A'
        assert result['response']['issueTokens'] == False
        assert result['response']['failAuthentication'] == False

        print("✅ PASS: First attempt requests password (SRP_A)")

    def test_second_attempt_password_correct(self):
        """
        Test: User submitted correct password
        Expected: Request CUSTOM_CHALLENGE (email MFA)
        """
        # Arrange
        session = [
            {
                'challengeName': 'SRP_A',
                'challengeResult': True
            }
        ]
        event = create_event(session)
        context = MockContext()

        # Act
        result = self.handler(event, context)

        # Assert
        assert result['response']['challengeName'] == 'CUSTOM_CHALLENGE'
        assert result['response']['issueTokens'] == False
        assert result['response']['failAuthentication'] == False

        print("✅ PASS: Correct password triggers email MFA")

    def test_second_attempt_password_incorrect(self):
        """
        Test: User submitted wrong password
        Expected: Fail authentication, no MFA sent
        """
        # Arrange
        session = [
            {
                'challengeName': 'SRP_A',
                'challengeResult': False
            }
        ]
        event = create_event(session)
        context = MockContext()

        # Act
        result = self.handler(event, context)

        # Assert
        assert result['response'].get('failAuthentication') == True
        assert result['response']['issueTokens'] == False
        assert 'challengeName' not in result['response'] or result['response'].get('challengeName') != 'CUSTOM_CHALLENGE'

        print("✅ PASS: Wrong password fails authentication (no MFA)")

    def test_third_attempt_mfa_correct(self):
        """
        Test: User submitted correct MFA code
        Expected: Issue tokens, grant access
        """
        # Arrange
        session = [
            {
                'challengeName': 'SRP_A',
                'challengeResult': True
            },
            {
                'challengeName': 'CUSTOM_CHALLENGE',
                'challengeResult': True
            }
        ]
        event = create_event(session)
        context = MockContext()

        # Act
        result = self.handler(event, context)

        # Assert
        assert result['response']['issueTokens'] == True
        assert result['response']['failAuthentication'] == False

        print("✅ PASS: Correct MFA code grants access")

    def test_third_attempt_mfa_incorrect(self):
        """
        Test: User submitted wrong MFA code
        Expected: Fail authentication
        """
        # Arrange
        session = [
            {
                'challengeName': 'SRP_A',
                'challengeResult': True
            },
            {
                'challengeName': 'CUSTOM_CHALLENGE',
                'challengeResult': False
            }
        ]
        event = create_event(session)
        context = MockContext()

        # Act
        result = self.handler(event, context)

        # Assert
        assert result['response']['failAuthentication'] == True
        assert result['response']['issueTokens'] == False

        print("✅ PASS: Wrong MFA code fails authentication")

    def test_too_many_attempts(self):
        """
        Test: User has made 4+ attempts
        Expected: Fail authentication (rate limiting)
        """
        # Arrange
        session = [
            {'challengeName': 'SRP_A', 'challengeResult': True},
            {'challengeName': 'CUSTOM_CHALLENGE', 'challengeResult': False},
            {'challengeName': 'CUSTOM_CHALLENGE', 'challengeResult': False},
            {'challengeName': 'CUSTOM_CHALLENGE', 'challengeResult': False}
        ]
        event = create_event(session)
        context = MockContext()

        # Act
        result = self.handler(event, context)

        # Assert
        assert result['response']['failAuthentication'] == True
        assert result['response']['issueTokens'] == False

        print("✅ PASS: Too many attempts triggers failure")


if __name__ == '__main__':
    # Run tests
    pytest.main([__file__, '-v', '-s'])
