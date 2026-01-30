"""
DefineAuthChallenge Lambda
Orchestrates the custom authentication flow for email-based MFA.

Flow:
- Session 0: User submits password -> Issue CUSTOM_CHALLENGE
- Session 1: Password validated -> Issue CUSTOM_CHALLENGE (email MFA)
- Session 2: MFA code validated -> Issue tokens
"""


def lambda_handler(event, context):
    """
    Determine the next authentication challenge or if authentication is complete.

    Args:
        event: Cognito event containing request and response objects
        context: Lambda context (unused)

    Returns:
        Modified event with response fields set
    """
    print(f"DefineAuthChallenge invoked. Session: {event['request']['session']}")

    # Get the current session array
    session = event['request']['session']

    # Initialize response defaults
    event['response']['issueTokens'] = False
    event['response']['failAuthentication'] = False

    if len(session) == 0:
        # First attempt - go straight to CUSTOM_CHALLENGE for email MFA
        # Password is validated by Cognito before invoking custom auth
        event['response']['challengeName'] = 'CUSTOM_CHALLENGE'
        print("Session 0: Issuing CUSTOM_CHALLENGE (email MFA)")

    elif len(session) == 1:
        # Second attempt - check if first MFA was correct
        if session[0]['challengeName'] == 'CUSTOM_CHALLENGE' and session[0]['challengeResult']:
            # MFA code was correct, issue tokens
            event['response']['issueTokens'] = True
            print("Session 1: MFA correct, issuing tokens")
        else:
            # MFA code was wrong, allow retry (issue new challenge)
            event['response']['challengeName'] = 'CUSTOM_CHALLENGE'
            print("Session 1: MFA incorrect, issuing new challenge")

    elif len(session) == 2:
        # Third attempt - check second MFA attempt
        if session[1]['challengeName'] == 'CUSTOM_CHALLENGE' and session[1]['challengeResult']:
            event['response']['issueTokens'] = True
            print("Session 2: MFA correct on retry, issuing tokens")
        else:
            # Two wrong attempts - fail authentication
            event['response']['failAuthentication'] = True
            print("Session 2: MFA incorrect again, failing authentication")

    else:
        # Too many failed attempts (3+)
        event['response']['failAuthentication'] = True
        print(f"Session {len(session)}: Too many attempts, failing authentication")

    print(f"Response: {event['response']}")
    return event
