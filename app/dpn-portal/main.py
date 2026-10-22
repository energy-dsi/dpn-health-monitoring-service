"""
DPN Portal - a single landing page linking out to every DPN observability UI
(Kafka UI, OpenSearch Dashboards, Jaeger), gated by the same Keycloak realm
as everything else.

Auth is NOT handled here. Like Kafka UI, OpenSearch Dashboards, and Jaeger,
this app sits behind an oauth2-proxy sidecar (see charts/dpn-portal) which
terminates the OIDC login. oauth2-proxy runs here in its default "proxy"
mode (it forwards requests straight to this app's upstream, rather than
being used as an nginx auth_request subrequest), so with
`pass_user_headers = true` it adds `X-Forwarded-User` and
`X-Forwarded-Groups` (comma-separated) to the request before it reaches
us. This app just reads those headers and filters which tiles to show -
no session/cookie/token handling of its own.

This module is only the app wiring and the routes; the logic lives in the
portal/ package - auth.py (identity headers), tiles.py (the home page card
catalogue). Templates are split into templates/pages (one per route, all
extending base.html) and templates/icons (inline SVG partials).
"""
import os
from urllib.parse import quote

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from portal.auth import current_user
from portal.health import annotate_reachability
from portal.tiles import visible_tiles

app = FastAPI(title="DPN Portal")

BASE_DIR = os.path.dirname(__file__)
templates = Jinja2Templates(directory=os.path.join(BASE_DIR, "templates"))
app.mount("/static", StaticFiles(directory=os.path.join(BASE_DIR, "static")), name="static")

# /oauth2/sign_out only clears THIS proxy's own session cookie - it does not
# touch Keycloak's SSO session. With skip_oidc_discovery=true (required for
# the split-horizon Keycloak setup - see charts/oauth2-proxy/README.md),
# oauth2-proxy never learns Keycloak's end_session_endpoint, so it cannot
# perform that step itself. Left as sign_out alone, a user who "logs out" is
# transparently re-authenticated on their very next request, and every other
# oauth2-proxy release (Jaeger, OpenSearch Dashboards, ...) stays signed in
# too, since they all share the same Keycloak SSO session.
#
# The fix is to chain through Keycloak's real logout endpoint: sign_out
# clears this cookie, then its rd= redirect sends the browser to Keycloak's
# own /protocol/openid-connect/logout, which is what actually ends the SSO
# session - and since every proxy shares that one session, logging out once
# from the portal signs the user out everywhere, not just this UI.
KEYCLOAK_PUBLIC_URL = os.environ.get("KEYCLOAK_PUBLIC_URL", "")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "")
# The browser-facing portal URL, NOT derived from the request. oauth2-proxy
# calls this app over plain http on its in-cluster Service address, and
# there is no ProxyHeadersMiddleware here to rewrite Starlette's view of the
# request - request.base_url would resolve to that internal
# http://dpn-portal...:8000/ address, which is both unreachable from a
# browser and not the exact string registered as this client's redirect
# URI, so Keycloak would reject it as post_logout_redirect_uri.
PORTAL_EXTERNAL_URL = os.environ.get("PORTAL_EXTERNAL_URL", "")


def _logout_url() -> str:
    if not KEYCLOAK_PUBLIC_URL or not KEYCLOAK_REALM or not PORTAL_EXTERNAL_URL:
        # Misconfigured rather than absent-by-design: at least clear this
        # proxy's own cookie instead of rendering a broken link.
        return "/oauth2/sign_out"

    keycloak_logout = (
        f"{KEYCLOAK_PUBLIC_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/logout"
        f"?client_id=dpn-service-client&post_logout_redirect_uri={quote(PORTAL_EXTERNAL_URL, safe='')}"
    )
    return f"/oauth2/sign_out?rd={quote(keycloak_logout, safe='')}"


# Ending the Keycloak SSO session above does NOT clear any other UI's
# session: every oauth2-proxy release keeps its own separate cookie
# (_oauth2_proxy_jaeger, _oauth2_proxy_kafka_ui, ...) precisely so their
# sessions don't collide, and all nine releases share one Keycloak client
# (dpn-service-client) - Keycloak's front-channel logout can only iframe ONE
# registered URL per client, so it cannot fan out to nine proxies on its own.
#
# OTHER_UI_URLS lists every other proxy's externalUrl (see
# charts/oauth2-proxy/values-*.yaml) so index.html can fire a
# /oauth2/sign_out beacon at each one - a plain cookie-clearing GET, safe to
# call cross-origin via <img> - before following the real Keycloak logout
# link above. Supplied via env var so this app never hardcodes cluster
# hostnames/ports; see charts/dpn-portal/values.yaml.
def _other_ui_urls() -> list[str]:
    raw = os.environ.get("OTHER_UI_URLS", "")
    return [u.strip() for u in raw.split(",") if u.strip()]


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    username, groups = current_user(request)
    return templates.TemplateResponse(
        request,
        "pages/index.html",
        {
            "tiles": annotate_reachability(visible_tiles(groups)),
            "username": username,
            "groups": sorted(groups),
            "active_page": "dashboard",
            "logout_url": _logout_url(),
            "other_sign_out_urls": [f"{u}/oauth2/sign_out" for u in _other_ui_urls()],
        },
    )


@app.get("/healthz")
def healthz():
    return {"status": "ok"}
