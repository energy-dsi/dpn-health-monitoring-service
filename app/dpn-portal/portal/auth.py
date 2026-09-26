"""
Reads the identity oauth2-proxy forwards to this app.

There is no auth logic here - the oauth2-proxy sidecar (see
charts/dpn-portal) terminates the OIDC login and injects the headers this
module parses. See main.py's docstring for how the two fit together.
"""
from fastapi import Request

# Keycloak grants these to every user automatically (offline_access for
# refresh tokens, uma_authorization for the authz services feature) - they
# ride along in the same "roles" claim as dpnadmin/dpnreader but aren't
# meaningful access-control groups, so they're filtered out for display
# and tile-matching purposes.
NOISE_ROLES = {"offline_access", "uma_authorization"}


def user_groups(request: Request) -> set[str]:
    # oauth2-proxy (proxy mode, pass_user_headers=true) forwards the
    # oidc_groups_claim value(s) here, comma-separated - see
    # charts/dpn-portal/templates/oauth2-proxy-configmap.yaml.
    raw = request.headers.get("X-Forwarded-Groups", "")
    groups = {g.strip() for g in raw.split(",") if g.strip()}
    return groups - NOISE_ROLES


def current_user(request: Request) -> tuple[str, set[str]]:
    groups = user_groups(request)
    # X-Forwarded-User is always the token's "sub" (a GUID), even with
    # user_id_claim set - oauth2-proxy puts the configured claim in this
    # separate header instead (confirmed via /debug/headers).
    username = request.headers.get("X-Forwarded-Preferred-Username", "")
    return username, groups
