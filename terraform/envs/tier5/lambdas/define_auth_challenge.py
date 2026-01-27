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
        # First attempt - no session history
        # User has not authenticated yet, trigger password challenge
        event['response']['challengeName'] = 'SRP_A'
        print("Session 0: Issuing SRP_A challenge (password)")

    elif len(session) == 1:
        # Second attempt - password challenge completed
        if session[0]['challengeName'] == 'SRP_A' and session[0]['challengeResult']:
            # Password was correct, now require email MFA
            event['response']['challengeName'] = 'CUSTOM_CHALLENGE'
            event['response']['issueTokens'] = False
            print("Session 1: Password correct, issuing CUSTOM_CHALLENGE (email MFA)")
        else:
            # Password was wrong
            event['response']['failAuthentication'] = True
            print("Session 1: Password incorrect, failing authentication")

    elif len(session) == 2:
        # Third attempt - MFA challenge completed
        if session[1]['challengeName'] == 'CUSTOM_CHALLENGE' and session[1]['challengeResult']:
            # MFA code was correct, issue tokens
            event['response']['issueTokens'] = True
            print("Session 2: MFA correct, issuing tokens")
        else:
            # MFA code was wrong
            event['response']['failAuthentication'] = True
            print("Session 2: MFA incorrect, failing authentication")

    else:
        # Too many failed attempts
        event['response']['failAuthentication'] = True
        print(f"Session {len(session)}: Too many attempts, failing authentication")

    print(f"Response: {event['response']}")
    return event
