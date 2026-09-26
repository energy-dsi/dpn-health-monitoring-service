"""
Best-effort reachability probe for the tile catalogue's components.

tiles.py deliberately never talks to a service - "up" there means "a URL is
configured". This module is the one place that actually opens a connection,
so the home page can tell a configured-but-down service apart from one that's
actually answering.
"""
import concurrent.futures
import os
import ssl
import urllib.error
import urllib.request

TIMEOUT_SECONDS = float(os.environ.get("COMPONENT_HEALTH_TIMEOUT", "2"))

# Components sit behind internal CAs/self-signed certs and an oauth2-proxy
# login redirect - a probe only needs to know the endpoint answers at all,
# so cert validation is skipped here. No credentials are ever sent.
_INSECURE_CONTEXT = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
_INSECURE_CONTEXT.check_hostname = False
_INSECURE_CONTEXT.verify_mode = ssl.CERT_NONE


def _is_reachable(url: str) -> bool:
    request = urllib.request.Request(url, method="HEAD")
    try:
        urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS, context=_INSECURE_CONTEXT)
        return True
    except urllib.error.HTTPError:
        # Any HTTP response - even a 3xx/4xx, e.g. an oauth2-proxy login
        # redirect - means the service is up and answering.
        return True
    except (urllib.error.URLError, OSError):
        return False


def _probe_target(component: dict) -> str:
    # "url" is the browser-facing link (see tiles.py) - some of those
    # addresses (the *.svc.cluster.local names published only in external/
    # corporate DNS, see charts/oauth2-proxy/README.md's DNS section) don't
    # resolve from inside this pod at all. "probe_url", when a component
    # sets one, is the real in-cluster address that answers the same
    # oauth2-proxy/service. Falls back to "url" for components where the
    # two are the same address (e.g. docker-compose, or a genuine in-cluster
    # Service name like Keycloak's).
    return component.get("probe_url") or component.get("url") or ""


def annotate_reachability(tiles: list[dict]) -> list[dict]:
    targets = {
        _probe_target(c) for t in tiles for c in t.get("components", []) if _probe_target(c)
    }
    if not targets:
        return tiles

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(targets)) as pool:
        reachable = dict(zip(targets, pool.map(_is_reachable, targets)))

    return [
        {
            **tile,
            "components": [
                {**c, "reachable": reachable.get(_probe_target(c)) if _probe_target(c) else None}
                for c in tile.get("components", [])
            ],
        }
        for tile in tiles
    ]
