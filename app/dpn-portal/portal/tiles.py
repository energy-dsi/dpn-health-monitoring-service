"""
The catalogue of service cards shown on the DPN Portal home page.

Card and component URLs come from the TILES_CONFIG env var so the same
image works in every environment (see charts/dpn-portal/values.yaml's
tiles:, which the chart renders straight into TILES_CONFIG). Nothing here
talks to a service - the portal only ever links out, so a component is
"up" here purely in the sense that someone configured a URL for it.
"""
import os
import json


# TILES_CONFIG is a JSON array supplied via env var (see charts/dpn-portal's
# ConfigMap). Each entry is a *group* card:
#   {"name", "subtitle", "description", "icon", "groups": [...],
#    "components": [{"name", "url"}]}
# "groups" lists which Keycloak groups/roles can see the card; both
# dpnadmin and dpnreader see every card by default today, since every
# downstream service already allows both groups at its own oauth2-proxy -
# tighten per-card here if a service should become admin-only later.
#
# Every component of every card is listed, but only the services that
# actually exist in this repo today have a URL. A component with no URL
# renders as a non-clickable "No status available" row - having a URL is
# what makes portal/health.py probe it for "Normal Operations" at all.


# Falls back to the master-realm admin console (built from the same
# KEYCLOAK_PUBLIC_URL main.py already reads for the logout link) when
# KEYCLOAK_CONSOLE_URL isn't set explicitly, so this tile still links
# somewhere useful even without a dedicated env var.
def _keycloak_console_url():
    explicit = os.environ.get("KEYCLOAK_CONSOLE_URL")
    if explicit:
        return explicit
    public_url = os.environ.get("KEYCLOAK_PUBLIC_URL", "")
    if not public_url:
        return ""
    return f"{public_url}/admin/master/console/"


# Component URLs below are literal copies of charts/dpn-portal/values.yaml's
# tiles: list - values.yaml is the single source of truth for these, so a
# service's URL only ever needs updating there. This list is what renders
# when TILES_CONFIG isn't set at all (see load_tiles() below); in a real
# deployment the chart always sets TILES_CONFIG from values.yaml's tiles:,
# so DEFAULT_TILES itself never runs there.
DEFAULT_TILES = [
    {
        "name": "Users & Roles",
        "subtitle": "",
        "description": "Manage DPN users, groups, and role assignments in Keycloak.",
        "icon": "users",
        # Rendered as a flat CTA card (see pages/index.html), not the usual
        # collapsible one - it only ever has this single Keycloak link.
        "variant": "alt",
        "groups": ["dpnadmin"],
        "components": [
            {"name": "Keycloak Console", "url": _keycloak_console_url()},
        ],
    },
    {
        "name": "Data",
        "subtitle": "Store",
        "description": "Logical storage location for Data Products that are ready for sharing",
        "icon": "kafka",
        "groups": ["dpnadmin", "dpnreader"],
        "components": [
            {
                "name": "Kafka Health UI",
                "url": "https://dpn-kafka-ui-external.ns-dpn-01.svc.cluster.local:8086",
            },
        ],
    },
    {
        "name": "Gateway",
        "subtitle": "",
        "description": "Manage the secure and controlled exposure of Data Products to authorised Consumers",
        "icon": "gateway",
        "groups": ["dpnadmin", "dpnreader"],
        "components": [
            {
                "name": "GRPC Gateway Client",
                "url": "http://dpn-federator-client-1-external.ns-dpn-01.svc.cluster.local:8085",
            },
        ],
    },
    {
        "name": "Security",
        "subtitle": "Services",
        "description": "Provides the foundational security capabilities required to support authentication, authorisation, and policy enforcement within the DPN.",
        "icon": "security",
        "groups": ["dpnadmin", "dpnreader"],
        "components": [
            {
                "name": "Certification Vault Service",
                "url": "https://dpn-vault-https-lb.ns-dpn-01.svc.cluster.local:8200",
            },
        ],
    },
    {
        "name": "Data",
        "subtitle": "Pipeline",
        "description": "Manage your pipelines.",
        "icon": "airflow",
        "groups": ["dpnadmin", "dpnreader"],
        "components": [
            {
                "name": "Pipeline Orchestrator",
                "url": "https://dpn-airflow-webserver-external.ns-dpn-01.svc.cluster.local:8080",
            },
        ],
    },
    {
        "name": "Health",
        "subtitle": "Monitoring Service",
        "description": "Supports the visibility and auditability of a Participant's compliance with DSI operational and behavioural requirement",
        "icon": "health",
        "groups": ["dpnadmin", "dpnreader"],
        "components": [
            {
                "name": "Log Stack",
                "url": "https://dpn-observability.ns-dpn-health-01.svc.cluster.local:5601",
                "probe_url": "https://dpn-oauth2-proxy-osd.ns-dpn-health-01.svc.cluster.local:5601",
            },
            {
                "name": "Traces Stack",
                "url": "https://dpn-observability.ns-dpn-health-01.svc.cluster.local:16686",
                "probe_url": "https://dpn-oauth2-proxy-jaeger.ns-dpn-health-01.svc.cluster.local:16686",
            },
            {
                "name": "Metrics Dashboard",
                "url": "https://dpn-observability.ns-dpn-health-01.svc.cluster.local:8083",
                "probe_url": "https://dpn-oauth2-proxy-perses.ns-dpn-health-01.svc.cluster.local:8083",
            },
            {
                "name": "Collector Stack",
                "url": "https://dpn-observability.ns-dpn-health-01.svc.cluster.local:8082",
                "probe_url": "https://dpn-kafka-health-ui.ns-dpn-health-01.svc.cluster.local:8082",
            },
        ],
    },
]

def _normalize(tile: dict) -> dict:
    # TILES_CONFIG (see charts/dpn-portal) supplies flat {"name", "url"}
    # entries - one link per card, no "components" list. DEFAULT_TILES
    # above already groups multiple links per card under "components".
    # The template only ever renders links from "components", so a flat
    # entry needs its lone url folded into one before it reaches the page.
    if "components" not in tile and tile.get("url"):
        tile = {**tile, "components": [{"name": tile["name"], "url": tile["url"]}]}
    return tile


def load_tiles() -> list[dict]:
    raw = os.environ.get("TILES_CONFIG")
    tiles = json.loads(raw) if raw else DEFAULT_TILES
    return [_normalize(t) for t in tiles]


def visible_tiles(groups: set[str]) -> list[dict]:
    return [t for t in load_tiles() if not t.get("groups") or groups & set(t["groups"])]
