# Add this route to /opt/employee-portal/app.py

@app.get("/settings", response_class=HTMLResponse)
async def settings(request: Request):
    """User account settings page - MFA configuration and password management."""
    email, groups = require_auth(request)

    return templates.TemplateResponse("settings.html", {
        "request": request,
        "email": email,
        "groups": groups
    })
