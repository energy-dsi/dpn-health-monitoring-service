"""
Unit tests for portal/health.py. Never hits a real network — urlopen is
monkeypatched in every test that would otherwise call it.
"""
import urllib.error

import portal.health as health


class _Response:
    def __init__(self, status):
        self.status = status


def test_is_reachable_true_on_200(monkeypatch):
    monkeypatch.setattr(health.urllib.request, "urlopen", lambda *a, **k: _Response(200))
    assert health._is_reachable("https://up.example") is True


def test_is_reachable_true_on_http_error(monkeypatch):
    # Any HTTP response - even a 3xx/4xx, e.g. an oauth2-proxy login
    # redirect for an unauthenticated probe - means the service is up.
    def raise_http_error(*a, **k):
        raise urllib.error.HTTPError("https://redirected.example", 302, "Found", {}, None)

    monkeypatch.setattr(health.urllib.request, "urlopen", raise_http_error)
    assert health._is_reachable("https://redirected.example") is True


def test_is_reachable_false_on_url_error(monkeypatch):
    def raise_url_error(*a, **k):
        raise urllib.error.URLError("down")

    monkeypatch.setattr(health.urllib.request, "urlopen", raise_url_error)
    assert health._is_reachable("https://down.example") is False


def test_is_reachable_false_on_os_error(monkeypatch):
    def raise_os_error(*a, **k):
        raise OSError("connection refused")

    monkeypatch.setattr(health.urllib.request, "urlopen", raise_os_error)
    assert health._is_reachable("https://down.example") is False


def test_annotate_reachability_skips_probe_when_no_urls(monkeypatch):
    def fail_if_called(url):
        raise AssertionError("should not probe a tile with no component URLs")

    monkeypatch.setattr(health, "_is_reachable", fail_if_called)
    tiles = [{"name": "Empty", "components": [{"name": "No URL", "url": ""}]}]
    assert health.annotate_reachability(tiles) == tiles


def test_annotate_reachability_marks_components(monkeypatch):
    monkeypatch.setattr(
        health,
        "_is_reachable",
        lambda url: url == "https://up.example",
    )
    tiles = [
        {
            "name": "Health",
            "components": [
                {"name": "Up Service", "url": "https://up.example"},
                {"name": "Down Service", "url": "https://down.example"},
                {"name": "Unconfigured", "url": ""},
            ],
        }
    ]

    annotated = health.annotate_reachability(tiles)

    components = annotated[0]["components"]
    assert components[0]["reachable"] is True
    assert components[1]["reachable"] is False
    assert components[2]["reachable"] is None


def test_annotate_reachability_probes_probe_url_not_browser_url(monkeypatch):
    # A component's "url" (browser-facing) can be unresolvable from this
    # pod - see the *.svc.cluster.local names in charts/dpn-portal/values.yaml
    # that only exist in external DNS. "probe_url" is what actually gets
    # probed when set.
    monkeypatch.setattr(
        health,
        "_is_reachable",
        lambda url: url == "https://internal.example",
    )
    tiles = [
        {
            "name": "Health",
            "components": [
                {
                    "name": "Log Stack",
                    "url": "https://public.example",
                    "probe_url": "https://internal.example",
                },
            ],
        }
    ]

    annotated = health.annotate_reachability(tiles)

    assert annotated[0]["components"][0]["reachable"] is True
