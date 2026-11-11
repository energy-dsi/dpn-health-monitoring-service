"""Unit tests for portal/tiles.py."""
import json

from portal.tiles import (
    DEFAULT_TILES,
    _keycloak_console_url,
    _normalize,
    load_tiles,
    visible_tiles,
)


def test_keycloak_console_url_explicit_env_var(monkeypatch):
    monkeypatch.setenv("KEYCLOAK_CONSOLE_URL", "https://console.example")
    monkeypatch.setenv("KEYCLOAK_PUBLIC_URL", "https://keycloak.example")
    assert _keycloak_console_url() == "https://console.example"


def test_keycloak_console_url_falls_back_to_public_url(monkeypatch):
    monkeypatch.delenv("KEYCLOAK_CONSOLE_URL", raising=False)
    monkeypatch.setenv("KEYCLOAK_PUBLIC_URL", "https://keycloak.example")
    assert _keycloak_console_url() == "https://keycloak.example/admin/master/console/"


def test_keycloak_console_url_empty_when_nothing_configured(monkeypatch):
    monkeypatch.delenv("KEYCLOAK_CONSOLE_URL", raising=False)
    monkeypatch.delenv("KEYCLOAK_PUBLIC_URL", raising=False)
    assert _keycloak_console_url() == ""


def test_normalize_folds_flat_url_into_components():
    tile = {"name": "Kafka UI", "url": "https://kafka.example"}
    normalized = _normalize(tile)
    assert normalized["components"] == [{"name": "Kafka UI", "url": "https://kafka.example"}]


def test_normalize_leaves_tile_with_components_unchanged():
    tile = {"name": "Health", "components": [{"name": "Log Stack", "url": "https://logs.example"}]}
    assert _normalize(tile) == tile


def test_normalize_leaves_tile_without_url_unchanged():
    tile = {"name": "Empty"}
    assert _normalize(tile) == tile


def test_load_tiles_returns_defaults_when_unset(monkeypatch):
    monkeypatch.delenv("TILES_CONFIG", raising=False)
    tiles = load_tiles()
    assert [t["name"] for t in tiles] == [t["name"] for t in DEFAULT_TILES]


def test_load_tiles_parses_and_normalizes_env_json(monkeypatch):
    custom = [{"name": "Custom", "url": "https://custom.example"}]
    monkeypatch.setenv("TILES_CONFIG", json.dumps(custom))
    tiles = load_tiles()
    assert tiles == [
        {
            "name": "Custom",
            "url": "https://custom.example",
            "components": [{"name": "Custom", "url": "https://custom.example"}],
        }
    ]


def test_visible_tiles_filters_by_group(monkeypatch):
    tiles = [
        {"name": "Admin Only", "groups": ["dpnadmin"], "components": []},
        {"name": "Reader Only", "groups": ["dpnreader"], "components": []},
    ]
    monkeypatch.setenv("TILES_CONFIG", json.dumps(tiles))
    visible = visible_tiles({"dpnadmin"})
    assert [t["name"] for t in visible] == ["Admin Only"]


def test_visible_tiles_shows_ungrouped_tile_to_everyone(monkeypatch):
    tiles = [{"name": "Everyone", "components": []}]
    monkeypatch.setenv("TILES_CONFIG", json.dumps(tiles))
    assert visible_tiles(set()) == tiles
