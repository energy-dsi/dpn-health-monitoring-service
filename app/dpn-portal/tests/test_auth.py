"""Unit tests for portal/auth.py."""
from fastapi import Request

from portal.auth import current_user, user_groups


def _request(headers: dict) -> Request:
    scope = {
        "type": "http",
        "headers": [(k.lower().encode(), v.encode()) for k, v in headers.items()],
    }
    return Request(scope)


def test_user_groups_parses_and_strips():
    request = _request({"X-Forwarded-Groups": " dpnadmin , dpnreader ,, "})
    assert user_groups(request) == {"dpnadmin", "dpnreader"}


def test_user_groups_filters_noise_roles():
    request = _request({"X-Forwarded-Groups": "dpnadmin,offline_access,uma_authorization"})
    assert user_groups(request) == {"dpnadmin"}


def test_user_groups_empty_header():
    request = _request({})
    assert user_groups(request) == set()


def test_current_user_returns_username_and_groups():
    request = _request(
        {
            "X-Forwarded-Groups": "dpnadmin",
            "X-Forwarded-Preferred-Username": "alice",
        }
    )
    username, groups = current_user(request)
    assert username == "alice"
    assert groups == {"dpnadmin"}


def test_current_user_empty_username_when_header_missing():
    request = _request({"X-Forwarded-Groups": "dpnreader"})
    username, groups = current_user(request)
    assert username == ""
    assert groups == {"dpnreader"}
