"""
MFA Setup Routes
Provides endpoints for TOTP-based Multi-Factor Authentication setup.
"""

import pyotp
import qrcode
import io
import base64
from fastapi import APIRouter, Request, HTTPException
from fastapi.responses import JSONResponse, HTMLResponse
from typing import Optional

# Create router
router = APIRouter()

# In-memory storage for MFA secrets (in production, store in database)
# Format: {email: {"secret": "...", "verified": False}}
mfa_secrets = {}

def require_auth(request: Request):
    """Extract user email from ALB headers."""
    from main import extract_user_from_alb_header
    email = extract_user_from_alb_header(request)
    if not email:
        raise HTTPException(status_code=401, detail="Not authenticated")
    return email


@router.get("/api/mfa/init")
async def initialize_mfa(request: Request):
    """
    Initialize MFA setup for the authenticated user.
    Returns a TOTP secret and QR code for scanning.
    """
    email = require_auth(request)

    # Generate a new TOTP secret
    secret = pyotp.random_base32()

    # Store the secret temporarily (not verified yet)
    mfa_secrets[email] = {
        "secret": secret,
        "verified": False
    }

    # Create TOTP URI for QR code
    # Format: otpauth://totp/CAPSULE:user@email.com?secret=SECRET&issuer=CAPSULE
    totp = pyotp.TOTP(secret)
    provisioning_uri = totp.provisioning_uri(
        name=email,
        issuer_name="CAPSULE Portal"
    )

    # Generate QR code as base64 image
    qr = qrcode.QRCode(version=1, box_size=10, border=5)
    qr.add_data(provisioning_uri)
    qr.make(fit=True)

    img = qr.make_image(fill_color="black", back_color="white")

    # Convert to base64
    buffer = io.BytesIO()
    img.save(buffer, format='PNG')
    buffer.seek(0)
    qr_base64 = base64.b64encode(buffer.getvalue()).decode()

    return JSONResponse({
        "success": True,
        "secret": secret,
        "qr_code": f"data:image/png;base64,{qr_base64}",
        "provisioning_uri": provisioning_uri
    })


@router.post("/api/mfa/verify")
async def verify_mfa_code(request: Request):
    """
    Verify the TOTP code entered by the user.
    If valid, marks MFA as configured for this user.
    """
    email = require_auth(request)

    # Get the verification code from request body
    try:
        body = await request.json()
        code = body.get("code", "").strip()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid request body")

    if not code or len(code) != 6:
        return JSONResponse({
            "success": False,
            "error": "Please enter a 6-digit code"
        }, status_code=400)

    # Check if user has initiated MFA setup
    if email not in mfa_secrets:
        return JSONResponse({
            "success": False,
            "error": "MFA setup not initialized. Please refresh and try again."
        }, status_code=400)

    secret = mfa_secrets[email]["secret"]

    # Verify the code
    totp = pyotp.TOTP(secret)
    is_valid = totp.verify(code, valid_window=1)  # Allow 1 time step window

    if is_valid:
        # Mark as verified
        mfa_secrets[email]["verified"] = True

        # In production: Save to Cognito or database
        # For now, we'll just store in memory

        return JSONResponse({
            "success": True,
            "message": "MFA successfully configured!"
        })
    else:
        return JSONResponse({
            "success": False,
            "error": "Invalid code. Please check your authenticator app and try again."
        }, status_code=400)


@router.get("/api/mfa/status")
async def get_mfa_status(request: Request):
    """
    Check if user has MFA configured.
    """
    email = require_auth(request)

    # Check if user has verified MFA
    has_mfa = email in mfa_secrets and mfa_secrets[email].get("verified", False)

    return JSONResponse({
        "email": email,
        "mfa_enabled": has_mfa
    })
