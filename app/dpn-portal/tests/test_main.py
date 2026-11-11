"""
Route/integration tests for main.py. main.KEYCLOAK_PUBLIC_URL /
KEYCLOAK_REALM / PORTAL_EXTERNAL_URL are read into module-level constants at
IMPORT time, so tests needing different values use monkeypatch.setattr(main,
...) rather than monkeypatch.setenv(...) (too late). TILES_CONFIG and
OTHER_UI_URLS are re-read from os.environ on every call, so those use
monkeypatch.setenv(...). annotate_reachability is monkeypatched to a no-op in
every route test, so these tests never touch the network -- portal/health.py
has its own dedicated, fully-mocked tests for that logic.
"""
import json

import pytest
from fastapi.testclient import TestClient

import main


@pytest.fixture(autouse=True)
def no_network_reachability_probe(monkeypatch):
    monkeypatch.setattr(main, "annotate_reachability", lambda tiles: tiles)


@pytest.fixture
def client():
    return TestClient(main.app)


def test_healthz_returns_ok(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_logout_url_falls_back_when_misconfigured(monkeypatch):
    monkeypatch.setattr(main, "KEYCLOAK_PUBLIC_URL", "")
    monkeypatch.setattr(main, "KEYCLOAK_REALM", "")
    monkeypatch.setattr(main, "PORTAL_EXTERNAL_URL", "")
    assert main._logout_url() == "/oauth2/sign_out"


def test_logout_url_builds_keycloak_chain_when_configured(monkeypatch):
    monkeypatch.setattr(main, "KEYCLOAK_PUBLIC_URL", "https://keycloak.example")
    monkeypatch.setattr(main, "KEYCLOAK_REALM", "dpn-realm")
    monkeypatch.setattr(main, "PORTAL_EXTERNAL_URL", "https://portal.example")

    url = main._logout_url()

    assert url.startswith("/oauth2/sign_out?rd=")
    assert "keycloak.example%2Frealms%2Fdpn-realm" in url
    assert "client_id%3Ddpn-service-client" in url
    assert "portal.example" in url


def test_other_ui_urls_parses_csv_and_strips(monkeypatch):
    monkeypatch.setenv("OTHER_UI_URLS", " https://a.example , https://b.example ,, ")
    assert main._other_ui_urls() == ["https://a.example", "https://b.example"]


def test_other_ui_urls_empty_when_unset(monkeypatch):
    monkeypatch.delenv("OTHER_UI_URLS", raising=False)
    assert main._other_ui_urls() == []


def test_index_shows_tiles_matching_user_groups(client, monkeypatch):
    tiles = [
        {"name": "Admin Only", "description": "d1", "icon": "security", "groups": ["dpnadmin"],
         "components": [{"name": "Admin Only", "url": "https://admin.example"}]},
        {"name": "Everyone", "description": "d2", "icon": "health", "groups": [],
         "components": [{"name": "Everyone", "url": "https://everyone.example"}]},
        {"name": "Reader Only", "description": "d3", "icon": "kafka", "groups": ["dpnreader"],
         "components": [{"name": "Reader Only", "url": "https://reader.example"}]},
    ]
    monkeypatch.setenv("TILES_CONFIG", json.dumps(tiles))

    response = client.get(
        "/",
        headers={
            "X-Forwarded-Groups": "dpnadmin",
            "X-Forwarded-Preferred-Username": "alice",
        },
    )

    assert response.status_code == 200
    assert "Admin Only" in response.text
    assert "Everyone" in response.text
    assert "Reader Only" not in response.text
    assert "alice" in response.text


def test_index_shows_empty_state_when_no_tiles_match(client, monkeypatch):
    tiles = [{"name": "Admin Only", "description": "d", "icon": "security", "groups": ["dpnadmin"],
              "components": [{"name": "Admin Only", "url": "https://admin.example"}]}]
    monkeypatch.setenv("TILES_CONFIG", json.dumps(tiles))

    response = client.get("/", headers={"X-Forwarded-Groups": "dpnreader"})

    assert response.status_code == 200
    assert "No services available" in response.text
    assert "No services are configured for your role." in response.text


def test_index_uses_fallback_logout_when_keycloak_unconfigured(client, monkeypatch):
    monkeypatch.setattr(main, "KEYCLOAK_PUBLIC_URL", "")
    monkeypatch.setattr(main, "KEYCLOAK_REALM", "")
    monkeypatch.setattr(main, "PORTAL_EXTERNAL_URL", "")
    monkeypatch.setenv("TILES_CONFIG", json.dumps([]))

    response = client.get("/", headers={"X-Forwarded-Preferred-Username": "bob"})

    assert response.status_code == 200
    assert 'href="/oauth2/sign_out"' in response.text


def test_index_fires_signout_beacons_for_other_uis(client, monkeypatch):
    monkeypatch.setenv("TILES_CONFIG", json.dumps([]))
    monkeypatch.setenv("OTHER_UI_URLS", "https://a.example,https://b.example")

    response = client.get("/")

    assert response.status_code == 200
    assert "https://a.example/oauth2/sign_out" in response.text
    assert "https://b.example/oauth2/sign_out" in response.text


def test_index_alt_variant_card_renders_as_flat_cta(client, monkeypatch):
    tiles = [
        {
            "name": "Users & Roles",
            "description": "Manage users.",
            "icon": "users",
            "variant": "alt",
            "groups": [],
            "components": [{"name": "Keycloak Console", "url": "https://keycloak.example/console"}],
        }
    ]
    monkeypatch.setenv("TILES_CONFIG", json.dumps(tiles))

    response = client.get("/")

    assert response.status_code == 200
    assert "Users &amp; Roles" in response.text or "Users & Roles" in response.text
    assert "https://keycloak.example/console" in response.text
