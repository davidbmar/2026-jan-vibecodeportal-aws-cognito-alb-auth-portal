# JWT Authentication & Authorization User Guide
## Implementing Portal-Based Authentication on EC2 Servers

**Version:** 1.0
**Last Updated:** January 28, 2026
**Portal:** https://portal.capsle-playground.com

---

## Table of Contents

1. [Overview](#overview)
2. [How JWT Authentication Works](#how-jwt-authentication-works)
3. [JWT Token Structure](#jwt-token-structure)
4. [Group-Based Authorization](#group-based-authorization)
5. [Implementation Guide](#implementation-guide)
6. [Code Examples](#code-examples)
7. [Security Best Practices](#security-best-practices)
8. [Troubleshooting](#troubleshooting)

---

## Overview

The CAPSULE Employee Portal (`portal.capsle-playground.com`) provides centralized authentication for all company applications. Users log in once via email-based MFA, and receive a **JWT (JSON Web Token)** that contains:

- Their identity (email address)
- Group memberships (engineering, hr, product, etc.)
- Token expiration time
- Authentication timestamp

Your EC2 application can trust these tokens to:
1. ✅ Verify the user logged into the portal
2. ✅ Extract the user's identity
3. ✅ Check group memberships for authorization
4. ✅ Implement group-based access control

---

## How JWT Authentication Works

### The Complete Flow

```
┌────────────┐                  ┌──────────────┐                  ┌─────────────┐
│   User     │                  │   Portal     │                  │  Your EC2   │
│            │                  │              │                  │     App     │
└────────────┘                  └──────────────┘                  └─────────────┘
      │                                │                                 │
      │  1. Visit portal.capsle-playground.com                          │
      ├──────────────────────────────>│                                 │
      │                                │                                 │
      │  2. Enter email                │                                 │
      ├──────────────────────────────>│                                 │
      │                                │                                 │
      │                           3. Send 6-digit                       │
      │                              MFA code via                        │
      │                              email (SES)                         │
      │<───────────────────────────────┤                                 │
      │                                │                                 │
      │  4. Enter 6-digit code         │                                 │
      ├──────────────────────────────>│                                 │
      │                                │                                 │
      │                           5. Verify code                         │
      │                              Generate JWT                        │
      │                              Extract groups                      │
      │                              Whitelist user IP                   │
      │                                │                                 │
      │  6. Set secure cookie          │                                 │
      │     auth_token=<JWT>           │                                 │
      │<───────────────────────────────┤                                 │
      │                                │                                 │
      │  7. User visits your app                                         │
      │     with cookie                                                  │
      ├──────────────────────────────────────────────────────────────>│
      │                                │                                 │
      │                                │             8. Extract JWT from │
      │                                │                cookie           │
      │                                │             9. Decode JWT       │
      │                                │            10. Verify expiry    │
      │                                │            11. Extract email &  │
      │                                │                groups           │
      │                                │            12. Check group      │
      │                                │                membership       │
      │                                │                                 │
      │  13. Return page (if authorized)                                │
      │<─────────────────────────────────────────────────────────────────┤
      │                                │                                 │
```

### Key Points

1. **Single Sign-On (SSO)**: Users authenticate once at the portal
2. **JWT in Cookie**: Token stored as `auth_token` HTTP-only secure cookie
3. **Stateless**: Your app doesn't need to query the portal or database
4. **Group Claims**: User's Cognito groups are embedded in the JWT
5. **IP Whitelisting**: Portal automatically whitelists user IP on matching EC2 instances

---

## JWT Token Structure

### What is a JWT?

A JWT is a **digitally signed JSON object** with three parts separated by dots:

```
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJlbWFpbCI6ImRtYXJAY2Fwc3VsZS5jb20iLCJjb2duaXRvOmdyb3VwcyI6WyJlbmdpbmVlcmluZyIsImFkbWlucyJdLCJleHAiOjE2NzQwMDQ4MzR9.signature
└──────────────────────┬───────────────────┘ └───────────────────────────────────────────────────────────────────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────┘ └────┬────┘
          HEADER (Base64)                                                           PAYLOAD (Base64)                                                                                                          SIGNATURE
```

### Decoded JWT Structure

#### Header
```json
{
  "alg": "RS256",
  "typ": "JWT",
  "kid": "abc123..."
}
```

#### Payload (Claims)
```json
{
  "sub": "12345678-1234-1234-1234-123456789abc",
  "email": "dmar@capsule.com",
  "email_verified": true,
  "cognito:username": "dmar@capsule.com",
  "cognito:groups": ["engineering", "admins"],
  "iss": "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_ABCDEF123",
  "aud": "7abcdefgh12345678",
  "token_use": "id",
  "auth_time": 1674001234,
  "iat": 1674001234,
  "exp": 1674004834
}
```

### Critical Claims for Your Application

| Claim | Description | Example | Usage |
|-------|-------------|---------|-------|
| `email` | User's email address | `"dmar@capsule.com"` | User identity |
| `cognito:groups` | Array of group names | `["engineering", "admins"]` | Authorization |
| `exp` | Expiration timestamp (Unix) | `1674004834` | Token validity |
| `iat` | Issued at timestamp (Unix) | `1674001234` | Audit logging |
| `iss` | Issuer (Cognito URL) | `"https://cognito-idp..."` | Trust verification |

### Token Lifetime

- **Duration:** 1 hour from issue time
- **Renewal:** User must re-authenticate at portal when expired
- **Validation:** Always check `exp` claim against current time

---

## Group-Based Authorization

### How Cognito Groups Work

Users are assigned to **Cognito groups** that represent:
- **Departments:** `engineering`, `hr`, `product`, `automation`
- **Roles:** `admins`, `managers`, `developers`
- **Projects:** Custom groups matching project names

### Group Types

#### 1. System Groups
Special groups for administrative purposes:
- `admins` - Full access to portal features
- Not used for EC2 area matching

#### 2. Area Groups
Groups that match EC2 instance tags (`VibeCodeArea`):
- `engineering` - Access to engineering servers
- `hr` - Access to HR systems
- `product` - Access to product environments

### IP Whitelisting Based on Groups

When a user logs into the portal:

1. **Group Extraction**: Portal decodes JWT and extracts `cognito:groups`
2. **Area Filtering**: Removes system groups (`admins`), keeps area groups
3. **Instance Matching**: Queries EC2 for instances with matching `VibeCodeArea` tag
4. **IP Rules Added**: User's IP is whitelisted on ports 80 & 443 for each matching instance

**Example:**
```python
# User: dmar@capsule.com
# Groups: ["engineering", "admins"]
# Client IP: 73.158.64.21

# Step 1: Filter to area groups
area_groups = ["engineering"]  # "admins" removed

# Step 2: Find matching instances
instances = get_instances_by_tag(VibeCodeArea="engineering")
# Found: i-0abc123def (test-server.capsle.com)

# Step 3: Add IP rules to instance security group
add_rule(
    security_group="sg-0123456789",
    port=80,
    cidr="73.158.64.21/32",
    description="User=dmar@capsule.com, IP=73.158.64.21, Port=80, Added=2026-01-28T10:30:00Z"
)
add_rule(
    security_group="sg-0123456789",
    port=443,
    cidr="73.158.64.21/32",
    description="User=dmar@capsule.com, IP=73.158.64.21, Port=443, Added=2026-01-28T10:30:00Z"
)
```

### Authorization Decision Matrix

| User Groups | Required Group | Access Granted? |
|-------------|----------------|-----------------|
| `["engineering"]` | `engineering` | ✅ Yes |
| `["engineering", "admins"]` | `engineering` | ✅ Yes |
| `["hr"]` | `engineering` | ❌ No |
| `["engineering", "product"]` | `product` | ✅ Yes |
| `[]` (no groups) | `engineering` | ❌ No |

---

## Implementation Guide

### Prerequisites

Your EC2 application needs:
1. Python 3.8+ (or equivalent JWT library in your language)
2. `PyJWT` library for token decoding
3. Access to read cookies from HTTP requests
4. Network connectivity (already configured via portal IP whitelisting)

### Step-by-Step Implementation

#### Step 1: Install Dependencies

**Python:**
```bash
pip install PyJWT cryptography
```

**Node.js:**
```bash
npm install jsonwebtoken
```

**Go:**
```bash
go get github.com/golang-jwt/jwt/v5
```

#### Step 2: Extract JWT from Cookie

The portal sets the JWT in a cookie named `auth_token`. Your application must read this cookie from incoming HTTP requests.

#### Step 3: Decode & Validate JWT

**Important:** You do NOT need to verify the JWT signature because:
- The portal (via AWS Cognito) has already cryptographically signed it
- The token was set by a trusted source (portal domain)
- Network access is already IP-restricted via security groups

However, you MUST:
- ✅ Check token expiration (`exp` claim)
- ✅ Verify issuer (`iss` claim) matches Cognito
- ✅ Extract and trust the claims

#### Step 4: Implement Authentication Middleware

Create middleware that:
1. Extracts `auth_token` cookie
2. Decodes JWT (without signature verification)
3. Validates expiration
4. Attaches user data to request context
5. Redirects to portal login if invalid/missing

#### Step 5: Implement Authorization Checks

For routes requiring specific groups:
1. Check if user's `cognito:groups` contains required group
2. Allow access if match found
3. Return 403 Forbidden if no match

---

## Code Examples

### Python (Flask/FastAPI)

#### Authentication Middleware

```python
import jwt
from datetime import datetime
from fastapi import Request, HTTPException
from fastapi.responses import RedirectResponse

# Cognito configuration (get from your infrastructure team)
COGNITO_REGION = "us-east-1"
COGNITO_USER_POOL_ID = "us-east-1_ABCDEF123"
COGNITO_ISSUER = f"https://cognito-idp.{COGNITO_REGION}.amazonaws.com/{COGNITO_USER_POOL_ID}"

def validate_token(token: str) -> dict:
    """
    Validate JWT token from portal cookie.

    Returns:
        dict: Decoded token payload with email and groups
        None: If token is invalid or expired
    """
    try:
        # Decode JWT without signature verification
        # (Portal/Cognito already verified it)
        payload = jwt.decode(
            token,
            options={
                "verify_signature": False,  # Trust portal signature
                "verify_aud": False,         # Skip audience check
                "verify_exp": True           # MUST check expiration
            }
        )

        # Verify issuer matches Cognito
        if payload.get('iss') != COGNITO_ISSUER:
            print(f"Invalid issuer: {payload.get('iss')}")
            return None

        # Verify token hasn't expired
        exp = payload.get('exp', 0)
        if datetime.utcnow().timestamp() > exp:
            print("Token expired")
            return None

        return payload

    except jwt.ExpiredSignatureError:
        print("Token expired")
        return None
    except jwt.InvalidTokenError as e:
        print(f"Invalid token: {e}")
        return None

@app.middleware("http")
async def auth_middleware(request: Request, call_next):
    """
    Middleware to validate JWT token on all requests.
    Redirects to portal login if not authenticated.
    """
    # Define public paths that don't require auth
    public_paths = ["/health", "/static", "/favicon.ico"]

    if any(request.url.path.startswith(path) for path in public_paths):
        return await call_next(request)

    # Extract token from cookie
    token = request.cookies.get("auth_token")

    if not token:
        print("No auth_token cookie found")
        return RedirectResponse(
            url="https://portal.capsle-playground.com/login",
            status_code=302
        )

    # Validate token
    user_data = validate_token(token)

    if not user_data:
        print("Invalid or expired token")
        return RedirectResponse(
            url="https://portal.capsle-playground.com/login",
            status_code=302
        )

    # Attach user data to request state
    request.state.user_email = user_data.get('email')
    request.state.user_groups = user_data.get('cognito:groups', [])
    request.state.auth_time = datetime.fromtimestamp(user_data.get('auth_time', 0))

    # Log authentication for audit trail
    print(f"[AUTH] User: {request.state.user_email} | "
          f"Groups: {request.state.user_groups} | "
          f"Path: {request.url.path}")

    response = await call_next(request)
    return response
```

#### Authorization Helper Functions

```python
from fastapi import Request, HTTPException

def require_auth(request: Request) -> tuple:
    """
    Get authenticated user email and groups.
    Raises 401 if not authenticated.

    Returns:
        tuple: (email: str, groups: list)
    """
    email = getattr(request.state, 'user_email', None)
    groups = getattr(request.state, 'user_groups', [])

    if not email:
        raise HTTPException(
            status_code=401,
            detail="Not authenticated. Please log in at portal.capsle-playground.com"
        )

    return email, groups

def require_group(request: Request, required_group: str) -> tuple:
    """
    Require user to be member of specific group.
    Returns None if not authorized (render 403 page).

    Args:
        request: FastAPI request object
        required_group: Group name required (e.g., "engineering")

    Returns:
        tuple: (email: str, groups: list) if authorized
        tuple: (None, None) if not authorized
    """
    email, groups = require_auth(request)

    if required_group not in groups:
        print(f"[AUTHZ-DENIED] User {email} missing required group: {required_group}")
        print(f"[AUTHZ-DENIED] User groups: {groups}")
        return None, None

    return email, groups

def require_any_group(request: Request, required_groups: list) -> tuple:
    """
    Require user to be member of at least one of the specified groups.

    Args:
        request: FastAPI request object
        required_groups: List of acceptable groups (e.g., ["engineering", "admins"])

    Returns:
        tuple: (email: str, groups: list) if authorized
        tuple: (None, None) if not authorized
    """
    email, groups = require_auth(request)

    if not any(group in groups for group in required_groups):
        print(f"[AUTHZ-DENIED] User {email} missing required groups: {required_groups}")
        print(f"[AUTHZ-DENIED] User groups: {groups}")
        return None, None

    return email, groups
```

#### Route Examples

```python
from fastapi import Request
from fastapi.responses import HTMLResponse, JSONResponse

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    """Public home page - anyone can access."""
    email, groups = require_auth(request)

    return f"""
    <html>
        <head><title>My App</title></head>
        <body>
            <h1>Welcome, {email}!</h1>
            <p>Your groups: {', '.join(groups)}</p>
            <p><a href="/engineering">Engineering Dashboard</a></p>
            <p><a href="/admin">Admin Panel</a></p>
        </body>
    </html>
    """

@app.get("/engineering", response_class=HTMLResponse)
async def engineering_dashboard(request: Request):
    """Engineering-only dashboard."""
    email, groups = require_group(request, "engineering")

    if not email:
        return HTMLResponse(
            content="<h1>403 Forbidden</h1><p>Engineering group required.</p>",
            status_code=403
        )

    return f"""
    <html>
        <head><title>Engineering Dashboard</title></head>
        <body>
            <h1>Engineering Dashboard</h1>
            <p>Welcome, {email}!</p>
            <p>This page is only accessible to engineering team members.</p>
        </body>
    </html>
    """

@app.get("/admin", response_class=HTMLResponse)
async def admin_panel(request: Request):
    """Admin panel - requires admins or engineering groups."""
    email, groups = require_any_group(request, ["admins", "engineering"])

    if not email:
        return HTMLResponse(
            content="<h1>403 Forbidden</h1><p>Admin or engineering access required.</p>",
            status_code=403
        )

    return f"""
    <html>
        <head><title>Admin Panel</title></head>
        <body>
            <h1>Admin Panel</h1>
            <p>Welcome, {email}!</p>
            <p>Your groups: {', '.join(groups)}</p>
        </body>
    </html>
    """

@app.get("/api/user", response_class=JSONResponse)
async def get_current_user(request: Request):
    """API endpoint returning current user info."""
    email, groups = require_auth(request)

    return {
        "email": email,
        "groups": groups,
        "authenticated": True
    }
```

### Node.js (Express)

```javascript
const express = require('express');
const jwt = require('jsonwebtoken');
const cookieParser = require('cookie-parser');

const app = express();
app.use(cookieParser());

// Cognito configuration
const COGNITO_REGION = 'us-east-1';
const COGNITO_USER_POOL_ID = 'us-east-1_ABCDEF123';
const COGNITO_ISSUER = `https://cognito-idp.${COGNITO_REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}`;

// Validate JWT token
function validateToken(token) {
    try {
        const decoded = jwt.decode(token, { complete: true });

        if (!decoded) {
            return null;
        }

        const payload = decoded.payload;

        // Check issuer
        if (payload.iss !== COGNITO_ISSUER) {
            console.log(`Invalid issuer: ${payload.iss}`);
            return null;
        }

        // Check expiration
        const now = Math.floor(Date.now() / 1000);
        if (now > payload.exp) {
            console.log('Token expired');
            return null;
        }

        return payload;

    } catch (error) {
        console.error('Token validation error:', error);
        return null;
    }
}

// Authentication middleware
function authMiddleware(req, res, next) {
    // Public paths
    const publicPaths = ['/health', '/static', '/favicon.ico'];
    if (publicPaths.some(path => req.path.startsWith(path))) {
        return next();
    }

    // Extract token
    const token = req.cookies.auth_token;

    if (!token) {
        return res.redirect('https://portal.capsle-playground.com/login');
    }

    // Validate token
    const userData = validateToken(token);

    if (!userData) {
        return res.redirect('https://portal.capsle-playground.com/login');
    }

    // Attach to request
    req.userEmail = userData.email;
    req.userGroups = userData['cognito:groups'] || [];

    console.log(`[AUTH] User: ${req.userEmail} | Groups: ${req.userGroups.join(', ')}`);

    next();
}

// Apply middleware
app.use(authMiddleware);

// Authorization helpers
function requireGroup(groupName) {
    return (req, res, next) => {
        if (!req.userGroups.includes(groupName)) {
            return res.status(403).send(`
                <h1>403 Forbidden</h1>
                <p>Group "${groupName}" required.</p>
            `);
        }
        next();
    };
}

// Routes
app.get('/', (req, res) => {
    res.send(`
        <h1>Welcome, ${req.userEmail}!</h1>
        <p>Your groups: ${req.userGroups.join(', ')}</p>
    `);
});

app.get('/engineering', requireGroup('engineering'), (req, res) => {
    res.send(`
        <h1>Engineering Dashboard</h1>
        <p>Welcome, ${req.userEmail}!</p>
    `);
});

app.listen(3000, () => {
    console.log('Server running on port 3000');
});
```

### Go (Gin Framework)

```go
package main

import (
    "fmt"
    "net/http"
    "strings"
    "time"

    "github.com/gin-gonic/gin"
    "github.com/golang-jwt/jwt/v5"
)

const (
    CognitoRegion     = "us-east-1"
    CognitoUserPoolID = "us-east-1_ABCDEF123"
)

var CognitoIssuer = fmt.Sprintf("https://cognito-idp.%s.amazonaws.com/%s",
    CognitoRegion, CognitoUserPoolID)

type TokenClaims struct {
    Email         string   `json:"email"`
    CognitoGroups []string `json:"cognito:groups"`
    jwt.RegisteredClaims
}

// ValidateToken validates JWT from cookie
func ValidateToken(tokenString string) (*TokenClaims, error) {
    // Parse without verification
    token, _, err := new(jwt.Parser).ParseUnverified(tokenString, &TokenClaims{})
    if err != nil {
        return nil, err
    }

    claims, ok := token.Claims.(*TokenClaims)
    if !ok {
        return nil, fmt.Errorf("invalid claims type")
    }

    // Check issuer
    if claims.Issuer != CognitoIssuer {
        return nil, fmt.Errorf("invalid issuer: %s", claims.Issuer)
    }

    // Check expiration
    if time.Now().Unix() > claims.ExpiresAt.Unix() {
        return nil, fmt.Errorf("token expired")
    }

    return claims, nil
}

// AuthMiddleware validates JWT on all requests
func AuthMiddleware() gin.HandlerFunc {
    return func(c *gin.Context) {
        // Public paths
        publicPaths := []string{"/health", "/static"}
        for _, path := range publicPaths {
            if strings.HasPrefix(c.Request.URL.Path, path) {
                c.Next()
                return
            }
        }

        // Extract token
        token, err := c.Cookie("auth_token")
        if err != nil {
            c.Redirect(http.StatusFound, "https://portal.capsle-playground.com/login")
            c.Abort()
            return
        }

        // Validate token
        claims, err := ValidateToken(token)
        if err != nil {
            fmt.Printf("Token validation error: %v\n", err)
            c.Redirect(http.StatusFound, "https://portal.capsle-playground.com/login")
            c.Abort()
            return
        }

        // Attach to context
        c.Set("user_email", claims.Email)
        c.Set("user_groups", claims.CognitoGroups)

        fmt.Printf("[AUTH] User: %s | Groups: %v\n",
            claims.Email, claims.CognitoGroups)

        c.Next()
    }
}

// RequireGroup middleware checks group membership
func RequireGroup(groupName string) gin.HandlerFunc {
    return func(c *gin.Context) {
        groups, _ := c.Get("user_groups")
        userGroups := groups.([]string)

        hasGroup := false
        for _, group := range userGroups {
            if group == groupName {
                hasGroup = true
                break
            }
        }

        if !hasGroup {
            c.HTML(http.StatusForbidden, "error.html", gin.H{
                "error": fmt.Sprintf("Group '%s' required", groupName),
            })
            c.Abort()
            return
        }

        c.Next()
    }
}

func main() {
    r := gin.Default()

    // Apply auth middleware
    r.Use(AuthMiddleware())

    // Routes
    r.GET("/", func(c *gin.Context) {
        email, _ := c.Get("user_email")
        groups, _ := c.Get("user_groups")

        c.HTML(http.StatusOK, "index.html", gin.H{
            "email":  email,
            "groups": groups,
        })
    })

    r.GET("/engineering", RequireGroup("engineering"), func(c *gin.Context) {
        email, _ := c.Get("user_email")

        c.HTML(http.StatusOK, "engineering.html", gin.H{
            "email": email,
        })
    })

    r.Run(":8080")
}
```

---

## Security Best Practices

### ✅ DO

1. **Always check token expiration** (`exp` claim)
2. **Verify issuer** matches your Cognito user pool
3. **Use HTTPS only** for all traffic (enforced by ALB)
4. **Log authentication events** for audit trail
5. **Check group membership** for authorization decisions
6. **Handle expired tokens gracefully** by redirecting to portal
7. **Use secure cookie settings** if you need to pass data between pages
8. **Validate request origin** if accepting API requests

### ❌ DON'T

1. **Don't store tokens in localStorage** (XSS risk) - use HTTP-only cookies
2. **Don't skip expiration checks** - expired tokens are invalid
3. **Don't trust client-side group claims** without server validation
4. **Don't hardcode Cognito configuration** - use environment variables
5. **Don't expose JWT in URLs** (e.g., query parameters)
6. **Don't implement your own JWT signing** - trust Cognito
7. **Don't cache tokens indefinitely** - respect expiration times
8. **Don't skip authentication on "internal" endpoints** - all routes need auth

### Cookie Security

If your application sets its own cookies:

```python
response.set_cookie(
    key="session_data",
    value=data,
    httponly=True,      # Prevents JavaScript access (XSS protection)
    secure=True,        # HTTPS only
    samesite="lax",     # CSRF protection
    max_age=3600        # 1 hour expiry
)
```

### Logging for Audit Trail

Always log authentication and authorization events:

```python
import logging
from datetime import datetime

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def log_auth_event(email: str, groups: list, path: str, client_ip: str):
    logger.info(
        f"[AUTH] {datetime.utcnow().isoformat()} | "
        f"User: {email} | "
        f"Groups: {','.join(groups)} | "
        f"Path: {path} | "
        f"IP: {client_ip}"
    )

def log_authz_denied(email: str, required_group: str, user_groups: list):
    logger.warning(
        f"[AUTHZ-DENIED] {datetime.utcnow().isoformat()} | "
        f"User: {email} | "
        f"Required: {required_group} | "
        f"User Groups: {','.join(user_groups)}"
    )
```

---

## Troubleshooting

### Problem: "No auth_token cookie found"

**Cause:** User hasn't logged into the portal or cookie expired.

**Solution:**
1. Redirect user to `https://portal.capsle-playground.com/login`
2. After login, portal will redirect back with valid cookie
3. Check cookie domain settings if using subdomains

### Problem: "Token expired"

**Cause:** JWT `exp` claim is older than current time (1-hour lifetime).

**Solution:**
1. Redirect user to portal to re-authenticate
2. Portal will issue new JWT after MFA verification

### Problem: "User not authorized (403 Forbidden)"

**Cause:** User's `cognito:groups` doesn't include required group.

**Solution:**
1. Verify user is assigned to correct Cognito group (contact admin)
2. Check group name spelling (case-sensitive)
3. Ensure group matching logic is correct:
   ```python
   # Correct
   if "engineering" in user_groups:

   # Wrong (exact match only)
   if user_groups == ["engineering"]:
   ```

### Problem: "Invalid issuer"

**Cause:** JWT `iss` claim doesn't match your Cognito user pool.

**Solution:**
1. Verify `COGNITO_ISSUER` constant matches your infrastructure
2. Check with infrastructure team for correct user pool ID
3. Format: `https://cognito-idp.{region}.amazonaws.com/{pool_id}`

### Problem: "User can't access application (network timeout)"

**Cause:** User's IP not whitelisted on EC2 security group.

**Solution:**
1. User must log into portal first (IP whitelisting happens at login)
2. Verify user's groups match EC2 instance's `VibeCodeArea` tag
3. Check security group rules on EC2 instance:
   ```bash
   aws ec2 describe-security-groups --group-ids sg-xxxxx
   ```

### Problem: "JWT decode error"

**Cause:** Malformed or corrupted JWT token.

**Solution:**
1. Check token extraction from cookie (no extra spaces/newlines)
2. Verify cookie isn't being modified by proxies
3. Use https://jwt.io to manually decode and inspect token
4. Log the raw token string for debugging (temporarily, remove in production)

### Debug Checklist

When implementing JWT auth, verify:

- [ ] PyJWT library installed (`pip list | grep PyJWT`)
- [ ] Cookie extraction working (`print(request.cookies.get('auth_token'))`)
- [ ] Token decodes successfully (`jwt.decode(token, options={"verify_signature": False})`)
- [ ] Expiration check working (`payload['exp'] > time.time()`)
- [ ] Groups extracted correctly (`payload.get('cognito:groups', [])`)
- [ ] Middleware applied to all routes except public paths
- [ ] User redirected to portal on auth failure
- [ ] Authorization logic checks group membership
- [ ] Logs show authentication events

---

## Configuration Reference

### Environment Variables

```bash
# AWS Cognito Configuration
export COGNITO_REGION="us-east-1"
export COGNITO_USER_POOL_ID="us-east-1_ABCDEF123"
export COGNITO_CLIENT_ID="7abcdefgh12345678"

# Portal Configuration
export PORTAL_URL="https://portal.capsle-playground.com"
export PORTAL_LOGIN_URL="${PORTAL_URL}/login"

# Application Configuration
export APP_PORT="8080"
export APP_ENV="production"
```

### Infrastructure Team Contact

For Cognito configuration values or troubleshooting:
- **User Pool ID:** Contact DevOps team
- **Group Assignment:** Contact HR or team lead
- **EC2 Tags:** Contact Infrastructure team
- **Security Group Issues:** Contact Network team

---

## Summary

### Key Takeaways

1. ✅ **Portal handles authentication** - Users log in once at portal.capsle-playground.com
2. ✅ **JWT in cookie** - Token automatically sent with requests to your app
3. ✅ **Decode, don't verify** - Trust the portal's signature, check expiration
4. ✅ **Groups in token** - `cognito:groups` claim contains user's groups
5. ✅ **IP whitelisting automatic** - Portal whitelists user IP at login
6. ✅ **Middleware pattern** - Validate token on all routes except public
7. ✅ **Group-based authorization** - Check `cognito:groups` for access control

### Quick Start Checklist

- [ ] Install JWT library (PyJWT, jsonwebtoken, etc.)
- [ ] Get Cognito configuration from infrastructure team
- [ ] Implement `validate_token()` function
- [ ] Create authentication middleware
- [ ] Add `require_auth()` helper
- [ ] Add `require_group()` helper for protected routes
- [ ] Configure logging for audit trail
- [ ] Test with different user groups
- [ ] Deploy and verify IP whitelisting works

---

**Questions or Issues?**

Contact the infrastructure team or refer to the portal codebase at `/home/ubuntu/cognito_alb_ec2/terraform/envs/tier5/`

**Last Updated:** January 28, 2026
