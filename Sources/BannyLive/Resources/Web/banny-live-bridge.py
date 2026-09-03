#!/usr/bin/env python3
"""Portable, dependency-free participant bridge for Banny Live.

The bridge makes outbound requests to a Banny Live room and to a participant's
AI. Room invitation and agent bearer credentials are accepted only through a
private JSON file; they are never command-line options.
"""

from __future__ import print_function

import argparse
import errno
import http.client
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import signal
import socket
import ssl
import stat
import sys
import time
import unicodedata
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote_to_bytes, urlencode, urlsplit, urlunsplit
from urllib.request import (
    HTTPRedirectHandler,
    ProxyHandler,
    Request,
    build_opener,
)
import uuid


VERSION = "1.1.0"
PROTOCOL = "banny.agent.v1"

MAX_CREDENTIAL_BYTES = 16 * 1024
MAX_AVATAR_BYTES = 64 * 1024
MAX_JOIN_BYTES = 64 * 1024
MAX_CONTEXT_BYTES = 64 * 1024
MAX_DECISION_BYTES = 16 * 1024
MAX_MUTATION_RESPONSE_BYTES = 16 * 1024

JOIN_TIMEOUT_SECONDS = 15.0
POLL_TIMEOUT_SECONDS = 35.0
MUTATION_TIMEOUT_SECONDS = 10.0
EMPTY_POLL_DELAY_SECONDS = 0.25
MAX_ROOM_REQUEST_ATTEMPTS = 3
POLL_RETRY_BACKOFF_SECONDS = (0.150, 0.300)
SUBMIT_RETRY_BACKOFF_SECONDS = (0.050, 0.100)
RETRYABLE_ROOM_STATUSES = frozenset((502, 503, 504))

KNOWN_ACTIONS = frozenset(
    ("move", "depth", "tilt", "expression", "jump", "flip",
     "rotate", "zoom", "reset", "reaction")
)
BODY_NAMES = frozenset(("orange", "original", "pink", "alien"))
TOKEN_RE = re.compile(r"^[A-Za-z0-9+./=_~-]{1,4096}$")
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9._~-]{1,200}$")
HEX = frozenset("0123456789abcdefABCDEF")
TRANSIENT_ERRNOS = frozenset(
    value for value in (
        getattr(errno, "EAGAIN", None),
        getattr(errno, "EWOULDBLOCK", None),
        getattr(errno, "ECONNABORTED", None),
        getattr(errno, "ECONNREFUSED", None),
        getattr(errno, "ECONNRESET", None),
        getattr(errno, "EHOSTDOWN", None),
        getattr(errno, "EHOSTUNREACH", None),
        getattr(errno, "ENETDOWN", None),
        getattr(errno, "ENETRESET", None),
        getattr(errno, "ENETUNREACH", None),
        getattr(errno, "EPIPE", None),
        getattr(errno, "ETIMEDOUT", None),
        10051,  # WSAENETUNREACH
        10053,  # WSAECONNABORTED
        10054,  # WSAECONNRESET
        10060,  # WSAETIMEDOUT
        10061,  # WSAECONNREFUSED
    ) if value is not None
)
TRANSIENT_GAI_CODES = frozenset(
    value for value in (
        getattr(socket, "EAI_AGAIN", None),
        11002,  # WSATRY_AGAIN
    ) if value is not None
)
TRANSIENT_HERROR_CODES = frozenset((2, 11002))  # TRY_AGAIN / WSATRY_AGAIN


class BridgeError(Exception):
    """Expected validation, protocol, or transport failure."""


class TransientNetworkError(BridgeError):
    """A socket/DNS/connect failure which is safe for bounded room retry."""


class SessionClosed(BridgeError):
    """The room revoked the admitted participant session."""


class StopRequested(BaseException):
    """Raised cooperatively from a process signal handler."""


class NoRedirectHandler(HTTPRedirectHandler):
    """Decline every redirect, including same-origin redirects."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        del req, fp, code, msg, headers, newurl
        return None


class HTTPResult(object):
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self.body = body


class HTTPClient(object):
    """Small urllib client with redirects disabled and bounded bodies."""

    def __init__(self, opener=None):
        # Ignore ambient proxy variables. This prevents participant bearers from
        # being handed to an unexpected local proxy and keeps loopback local.
        self._opener = opener or build_opener(ProxyHandler({}), NoRedirectHandler())

    def request(self, method, url, body=None, bearer=None, timeout=10.0,
                response_limit=MAX_MUTATION_RESPONSE_BYTES,
                request_limit=MAX_CONTEXT_BYTES):
        if body is not None and len(body) > request_limit:
            raise BridgeError(
                "request exceeds the {}-byte limit".format(request_limit))
        headers = {
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "Cache-Control": "no-store",
            "User-Agent": "BannyLivePortableBridge/{}".format(VERSION),
        }
        if body is not None:
            headers["Content-Type"] = "application/json; charset=utf-8"
            headers["Content-Length"] = str(len(body))
        if bearer is not None:
            _validate_bearer(bearer, "bearer token")
            headers["Authorization"] = "Bearer " + bearer

        request = Request(url, data=body, headers=headers, method=method)
        try:
            response = self._opener.open(request, timeout=timeout)
        except HTTPError as error:
            status = getattr(error, "code", 0)
            try:
                self._validate_response_head(error, url, status)
                if 300 <= status < 400:
                    raise BridgeError("HTTP redirects are not allowed")
                # A known authentication result wins over an unreadable error
                # body. Poll and submit map this status to clean session closure;
                # join and local-agent callers retain their route-specific rules.
                if status == 401:
                    return HTTPResult(status, {}, b"")
                try:
                    result = self._result_from_stream(
                        error, url, response_limit, status)
                except (http.client.IncompleteRead,
                        http.client.RemoteDisconnected,
                        http.client.BadStatusLine,
                        http.client.LineTooLong,
                        OSError) as read_error:
                    raise _classified_response_read_error(read_error, status)
            finally:
                error.close()
            return result
        except (URLError, socket.timeout, TimeoutError, OSError,
                http.client.IncompleteRead,
                http.client.RemoteDisconnected,
                http.client.BadStatusLine,
                http.client.LineTooLong) as error:
            raise _classified_transport_error(error)

        try:
            status = getattr(response, "status", 0)
            self._validate_response_head(response, url, status)
            if 300 <= status < 400:
                raise BridgeError("HTTP redirects are not allowed")
            if status == 401:
                return HTTPResult(status, {}, b"")
            try:
                return self._result_from_stream(
                    response, url, response_limit, status)
            except (http.client.IncompleteRead,
                    http.client.RemoteDisconnected,
                    http.client.BadStatusLine,
                    http.client.LineTooLong,
                    OSError) as read_error:
                raise _classified_response_read_error(
                    read_error, status)
        finally:
            response.close()

    @staticmethod
    def _validate_response_head(stream, expected_url, status):
        actual_url = stream.geturl()
        if actual_url != expected_url:
            raise BridgeError("HTTP redirects are not allowed")
        if not isinstance(status, int) or status < 100 or status > 599:
            raise BridgeError("invalid HTTP response status")

    @staticmethod
    def _result_from_stream(stream, expected_url, limit, status):
        HTTPClient._validate_response_head(stream, expected_url, status)
        content_lengths = _header_values(stream.headers, "Content-Length")
        transfer_encodings = _header_values(stream.headers, "Transfer-Encoding")
        if len(content_lengths) > 1:
            raise BridgeError("HTTP response has multiple Content-Length headers")
        if content_lengths and transfer_encodings:
            raise BridgeError(
                "HTTP response combines Content-Length and Transfer-Encoding")
        if transfer_encodings and any(
                value.strip().lower() != "chunked" for value in transfer_encodings):
            raise BridgeError("HTTP response uses an unsupported Transfer-Encoding")
        headers = {key.lower(): value for key, value in stream.headers.items()}
        encoding = headers.get("content-encoding", "identity").strip().lower()
        if encoding not in ("", "identity"):
            raise BridgeError("compressed HTTP responses are not accepted")
        body = _read_bounded(stream, headers, limit)
        return HTTPResult(status, headers, body)


class Reporter(object):
    def __init__(self, json_output=False, stdout=None, stderr=None):
        self.json_output = json_output
        self.stdout = stdout or sys.stdout
        self.stderr = stderr or sys.stderr

    def ready(self, room_id, participant_id, seat):
        if self.json_output:
            self._record(self.stdout, {
                "ok": True,
                "operation": "room_join",
                "participant_id": participant_id,
                "room_id": room_id,
                "seat": seat,
            })
        else:
            print(
                "joined room {} (seat {}, participant {})".format(
                    room_id, seat, participant_id),
                file=self.stdout,
                flush=True,
            )
            print(
                "portable bridge ready - room and local AI connections are outbound",
                file=self.stdout,
                flush=True,
            )

    def skipped(self, cursor, request_id, reason):
        safe = _safe_text(reason, 512)
        if self.json_output:
            self._record(self.stderr, {
                "cursor": cursor,
                "event": "decision_skipped",
                "message": safe,
                "request_id": request_id,
            })
        else:
            print(
                "local AI skipped request {}: {}".format(request_id, safe),
                file=self.stderr,
                flush=True,
            )

    def closed(self):
        if not self.json_output:
            print("room bridge closed", file=self.stdout, flush=True)

    def stopping(self):
        if not self.json_output:
            print("leaving room", file=self.stdout, flush=True)

    def error(self, reason):
        if self.json_output:
            self._record(self.stderr, {
                "error": {"code": "bridge_failed", "message": _safe_text(reason, 512)},
                "ok": False,
            })
        else:
            print(
                "banny-live-bridge: {}".format(_safe_text(reason, 512)),
                file=self.stderr,
                flush=True,
            )

    @staticmethod
    def _record(destination, value):
        print(
            json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True),
            file=destination,
            flush=True,
        )


class Credentials(object):
    def __init__(self, identity=None, invite=None, agent_token=None):
        self.identity = identity
        self.invite = invite
        self.agent_token = agent_token


class RoomEndpoint(object):
    def __init__(self, room_id, api_url):
        self.room_id = room_id
        self.api_url = api_url.rstrip("/")

    def child(self, *segments):
        encoded = [quote(segment, safe="-._~") for segment in segments]
        return self.api_url + "/" + "/".join(encoded)


class JoinReceipt(object):
    def __init__(self, participant_id, session_token, seat):
        self.participant_id = participant_id
        self.session_token = session_token
        self.seat = seat


class Bridge(object):
    def __init__(self, endpoint, agent_url, display_name, avatar, credentials,
                 allow_remote_agent=False, http=None, reporter=None,
                 empty_poll_delay=EMPTY_POLL_DELAY_SECONDS, sleeper=time.sleep,
                 clock=time.monotonic):
        self.endpoint = endpoint
        self.agent_url = normalize_agent_url(agent_url, allow_remote_agent)
        self.display_name = _validate_display_name(display_name)
        self.avatar = avatar
        self.credentials = credentials
        self.http = http or HTTPClient()
        self.reporter = reporter or Reporter()
        self.empty_poll_delay = empty_poll_delay
        self.sleeper = sleeper
        self.clock = clock
        self.receipt = None

    def join(self):
        payload = {
            "avatar": self.avatar,
            "display_name": self.display_name,
        }
        if self.credentials.identity is not None:
            payload["identity"] = self.credentials.identity
        if self.credentials.invite is not None:
            payload["invite"] = self.credentials.invite
        result = self.http.request(
            "POST",
            self.endpoint.child("join"),
            body=_encode_json(payload, MAX_JOIN_BYTES, "join request"),
            timeout=JOIN_TIMEOUT_SECONDS,
            response_limit=MAX_JOIN_BYTES,
            request_limit=MAX_JOIN_BYTES,
        )
        if result.status < 200 or result.status >= 300:
            raise _room_status_error(result, "admission")
        receipt = _parse_join_receipt(result)
        self.receipt = receipt
        return receipt

    def run(self):
        if self.receipt is None:
            raise BridgeError("join must complete before the polling loop starts")
        cursor = None
        while True:
            try:
                context = self._poll(cursor)
                if context is None:
                    if self.empty_poll_delay > 0:
                        self.sleeper(self.empty_poll_delay)
                    continue
                basis_seq = context["basis_seq"]
                if cursor is not None and basis_seq <= cursor:
                    raise BridgeError("room returned a non-advancing decision cursor")
                decision_started_at = self.clock()
                try:
                    decision = self._decide(context)
                except BridgeError as error:
                    decision = {
                        "actions": [],
                        "intent_id": "bridge-skip-{}".format(uuid.uuid4()),
                        "protocol": PROTOCOL,
                        "request_id": context["request_id"],
                    }
                    self._submit(decision, context, decision_started_at)
                    self.reporter.skipped(
                        basis_seq, context["request_id"], str(error))
                else:
                    self._submit(decision, context, decision_started_at)
                cursor = basis_seq
            except SessionClosed:
                self.reporter.closed()
                return "closed"

    def leave(self):
        if self.receipt is None:
            return
        result = self.http.request(
            "POST",
            self.endpoint.child("leave"),
            body=b"",
            bearer=self.receipt.session_token,
            timeout=MUTATION_TIMEOUT_SECONDS,
            response_limit=MAX_MUTATION_RESPONSE_BYTES,
            request_limit=0,
        )
        if result.status == 401:
            return
        if result.status < 200 or result.status >= 300:
            raise _room_status_error(result, "leave")

    def leave_best_effort(self):
        try:
            self.leave()
        except (BridgeError, StopRequested, KeyboardInterrupt):
            pass

    def _poll(self, cursor):
        url = self.endpoint.child("decisions", "next")
        if cursor is not None:
            url += "?" + urlencode({"after": str(cursor)})
        deadline = self.clock() + POLL_TIMEOUT_SECONDS
        result = self._room_request_with_retry(
            "GET",
            url,
            bearer=self.receipt.session_token,
            deadline=deadline,
            backoffs=POLL_RETRY_BACKOFF_SECONDS,
            response_limit=MAX_CONTEXT_BYTES,
            request_limit=0,
        )
        if result.status == 401:
            raise SessionClosed()
        if result.status == 204:
            if result.body:
                raise BridgeError("room returned a body with HTTP 204")
            return None
        if result.status != 200:
            raise _room_status_error(result, "decision poll")
        _require_json_content_type(result.headers, "room decision context")
        value = _decode_json(result.body, "room decision context")
        return validate_context(
            value,
            expected_room_id=self.endpoint.room_id,
            expected_participant_id=self.receipt.participant_id,
        )

    def _decide(self, context):
        body = _encode_json(context, MAX_CONTEXT_BYTES, "agent context")
        advertised = min(context["timeout_ms"], 10000)
        slack = min(500, max(50, advertised // 5))
        timeout = max(50, advertised - slack) / 1000.0
        result = self.http.request(
            "POST",
            self.agent_url,
            body=body,
            bearer=self.credentials.agent_token,
            timeout=timeout,
            response_limit=MAX_DECISION_BYTES,
            request_limit=MAX_CONTEXT_BYTES,
        )
        if result.status < 200 or result.status >= 300:
            raise BridgeError(
                "local agent returned HTTP {}".format(result.status))
        _require_json_content_type(result.headers, "local agent decision")
        decision = _decode_json(result.body, "local agent decision")
        return validate_decision(decision, context)

    def _submit(self, decision, context, decision_started_at):
        body = _encode_json(decision, MAX_DECISION_BYTES, "decision")
        context_deadline = (
            decision_started_at + (context["timeout_ms"] / 1000.0))
        now = self.clock()
        if now >= context_deadline:
            raise BridgeError("decision context deadline expired before submission")
        deadline = min(context_deadline, now + MUTATION_TIMEOUT_SECONDS)
        result = self._room_request_with_retry(
            "POST",
            self.endpoint.child("decisions", decision["request_id"]),
            body=body,
            bearer=self.receipt.session_token,
            deadline=deadline,
            backoffs=SUBMIT_RETRY_BACKOFF_SECONDS,
            response_limit=MAX_MUTATION_RESPONSE_BYTES,
            request_limit=MAX_DECISION_BYTES,
        )
        if result.status == 401:
            raise SessionClosed()
        if result.status < 200 or result.status >= 300:
            raise _room_status_error(result, "decision submission")

    def _room_request_with_retry(self, method, url, deadline,
                                 backoffs, **request_options):
        """Retry only a safe room poll or correlated decision submission."""
        if not math.isfinite(deadline):
            raise BridgeError("room request retry deadline expired")
        if len(backoffs) != MAX_ROOM_REQUEST_ATTEMPTS - 1:
            raise BridgeError("invalid room retry policy")
        failed_attempts = 0
        while True:
            now = self.clock()
            if now >= deadline:
                raise BridgeError("room request retry deadline expired")
            attempts_remaining = MAX_ROOM_REQUEST_ATTEMPTS - failed_attempts
            remaining = deadline - now
            reserved_backoff = min(remaining, sum(backoffs[failed_attempts:]))
            attempt_pool = max(0.0, remaining - reserved_backoff)
            attempt_timeout = min(
                remaining,
                max(0.001, attempt_pool / attempts_remaining),
            )

            failure = None
            try:
                result = self.http.request(
                    method,
                    url,
                    timeout=attempt_timeout,
                    **request_options
                )
            except TransientNetworkError as error:
                failure = error
            else:
                if result.status not in RETRYABLE_ROOM_STATUSES:
                    if self.clock() >= deadline:
                        raise BridgeError("room request retry deadline expired")
                    return result
                failure = result

            failed_attempts += 1
            if failed_attempts >= MAX_ROOM_REQUEST_ATTEMPTS:
                return _finish_retry_failure(failure)
            delay = backoffs[failed_attempts - 1]
            now = self.clock()
            if now >= deadline or delay >= deadline - now:
                return _finish_retry_failure(failure)
            self.sleeper(delay)


def normalize_room_url(raw):
    parts = _split_http_url(raw, "room URL")
    if parts.scheme == "http" and not is_numeric_loopback(parts.hostname):
        raise BridgeError("room URL must use HTTPS unless it targets numeric loopback")
    segments = _decoded_path_segments(parts.path, "room URL")
    if len(segments) in (2, 3) and segments[:1] == ["rooms"]:
        if len(segments) == 3 and segments[2] not in ("live", "join"):
            raise BridgeError("room URL has an unsupported public room path")
        room_id = segments[1]
    elif len(segments) == 3 and segments[:2] == ["v1", "rooms"]:
        room_id = segments[2]
    else:
        raise BridgeError(
            "room URL path must be /rooms/<id>[/live|join] or /v1/rooms/<id>")
    if not _is_safe_room_id(room_id):
        raise BridgeError("room URL contains an invalid room identifier")
    netloc = _normalized_netloc(parts)
    api_path = "/v1/rooms/" + quote(room_id, safe="-._~")
    return RoomEndpoint(room_id, urlunsplit((parts.scheme, netloc, api_path, "", "")))


def normalize_agent_url(raw, allow_remote=False):
    parts = _split_http_url(raw, "agent URL")
    if parts.path not in ("", "/"):
        raise BridgeError("agent URL must be an HTTP(S) origin without a path")
    loopback = is_numeric_loopback(parts.hostname)
    if not loopback and not allow_remote:
        raise BridgeError(
            "agent URL must use numeric loopback unless --allow-remote-agent is set")
    if not loopback and parts.scheme != "https":
        raise BridgeError("a remote agent URL must use HTTPS")
    netloc = _normalized_netloc(parts)
    return urlunsplit((parts.scheme, netloc, "/v1/decide", "", ""))


def is_numeric_loopback(host):
    if not host or "%" in host:
        return False
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    if isinstance(address, ipaddress.IPv4Address):
        return address.is_loopback
    return address == ipaddress.IPv6Address("::1")


def load_credentials(path):
    data = _read_regular_file(path, MAX_CREDENTIAL_BYTES, private=True)
    value = _decode_json(data, "credentials file")
    _require_exact_keys(
        value, required=(), optional=("identity", "invite", "agent_token"),
        label="credentials file")
    for key in ("identity", "invite", "agent_token"):
        if key in value and value[key] is not None and not isinstance(value[key], str):
            raise BridgeError("credentials file fields must be strings or null")
    identity = value.get("identity")
    invite = value.get("invite")
    agent_token = value.get("agent_token")
    if identity is not None:
        _validate_visible(identity, "credentials identity", 200, byte_limit=True)
    if invite is not None:
        _validate_visible(invite, "credentials invitation", 4096)
    if agent_token is not None:
        _validate_bearer(agent_token, "credentials agent_token")
    return Credentials(identity, invite, agent_token)


def load_avatar(path):
    data = _read_regular_file(path, MAX_AVATAR_BYTES, private=False)
    value = _decode_json(data, "avatar JSON")
    _require_exact_keys(
        value, required=("body", "eyes", "mouth", "outfit"), optional=(),
        label="avatar JSON")
    if value["body"] not in BODY_NAMES:
        raise BridgeError("avatar body is not a supported Banny body")
    _validate_visible(value["eyes"], "avatar eyes", 200, byte_limit=True)
    _validate_visible(value["mouth"], "avatar mouth", 200, byte_limit=True)
    outfit = value["outfit"]
    if not isinstance(outfit, dict) or len(outfit) > 32:
        raise BridgeError("avatar outfit must be an object with at most 32 entries")
    for raw_slot, name in outfit.items():
        if not isinstance(raw_slot, str) or not re.match(r"^[1-9][0-9]?$", raw_slot):
            raise BridgeError("avatar outfit slots must be canonical positive integers")
        _validate_visible(name, "avatar outfit name", 200, byte_limit=True)
    return value


def validate_context(value, expected_room_id, expected_participant_id):
    _require_exact_keys(
        value,
        required=("protocol", "request_id", "room_id", "participant_id",
                  "basis_seq", "timeout_ms", "context"),
        optional=(),
        label="room decision context",
    )
    if value["protocol"] != PROTOCOL:
        raise BridgeError("room returned an unsupported agent protocol")
    _validate_identifier(value["request_id"], "context request_id", 128)
    _validate_identifier(value["room_id"], "context room_id", 128)
    _validate_identifier(value["participant_id"], "context participant_id", 128)
    if value["room_id"] != expected_room_id:
        raise BridgeError("room decision context has the wrong room_id")
    if value["participant_id"] != expected_participant_id:
        raise BridgeError("room decision context has the wrong participant_id")
    basis = _require_int(
        value["basis_seq"], "context basis_seq", minimum=0,
        maximum=(1 << 63) - 1)
    _require_int(value["timeout_ms"], "context timeout_ms", minimum=100, maximum=10000)

    context = value["context"]
    _require_exact_keys(
        context,
        required=("scene_time_ms", "room", "self_state", "cast",
                  "recent_events", "constraints"),
        optional=(),
        label="context",
    )
    _require_int(
        context["scene_time_ms"], "context scene_time_ms", minimum=0,
        maximum=(1 << 63) - 1)
    _validate_room_context(context["room"])
    _validate_participant_context(context["self_state"])
    if context["self_state"]["participant_id"] != expected_participant_id:
        raise BridgeError("context self_state does not match participant_id")
    cast = context["cast"]
    if not isinstance(cast, list) or len(cast) > 10:
        raise BridgeError("context cast must be an array with at most 10 participants")
    for participant in cast:
        _validate_participant_context(participant)
    events = context["recent_events"]
    if not isinstance(events, list) or len(events) > 32:
        raise BridgeError("context recent_events must contain at most 32 events")
    for event in events:
        _validate_recent_event(event, basis)
    _validate_constraints(context["constraints"])
    return value


def validate_decision(value, context):
    _require_exact_keys(
        value,
        required=("protocol", "request_id", "intent_id", "actions"),
        optional=("say", "request_after_ms"),
        label="local agent decision",
    )
    if value["protocol"] != PROTOCOL:
        raise BridgeError("local agent returned an unsupported protocol")
    if value["request_id"] != context["request_id"]:
        raise BridgeError("local agent request_id did not match the outstanding request")
    _validate_identifier(value["intent_id"], "decision intent_id", 128)
    constraints = context["context"]["constraints"]
    if "say" in value and value["say"] is not None:
        if not isinstance(value["say"], str):
            raise BridgeError("decision say must be a string or null")
        if _has_forbidden_text(value["say"]):
            raise BridgeError("decision say contains control characters")
        if len(value["say"]) > min(280, constraints["max_speech_chars"]):
            raise BridgeError("decision say exceeds the advertised character limit")
    actions = value["actions"]
    maximum_actions = min(4, constraints["max_actions"])
    if not isinstance(actions, list) or len(actions) > maximum_actions:
        raise BridgeError("decision contains too many actions")
    groups = set()
    for action in actions:
        group = _validate_action(action, constraints)
        if group is not None:
            if group in groups:
                raise BridgeError("decision repeats a performance action group")
            groups.add(group)
    if "request_after_ms" in value and value["request_after_ms"] is not None:
        _require_int(
            value["request_after_ms"], "decision request_after_ms",
            minimum=250, maximum=10000)
    return value


def _validate_action(action, constraints):
    if not isinstance(action, dict) or not isinstance(action.get("op"), str):
        raise BridgeError("decision action must be an object with an op")
    op = action["op"]
    if op not in constraints["allowed_actions"]:
        raise BridgeError("decision action is not allowed by the room")
    duration_max = min(3000, constraints["max_action_ms"])
    if op in ("move", "rotate"):
        _require_exact_keys(action, ("op", "direction", "duration_ms"), (), "action")
        _require_choice(action["direction"], ("left", "right"), "action direction")
        _require_int(action["duration_ms"], "action duration_ms", 80, duration_max)
        return "move" if op == "move" else "spin"
    if op == "depth":
        _require_exact_keys(action, ("op", "direction", "duration_ms"), (), "action")
        _require_choice(action["direction"], ("away", "toward"), "action direction")
        _require_int(action["duration_ms"], "action duration_ms", 80, duration_max)
        return "depth"
    if op == "tilt":
        _require_exact_keys(action, ("op", "direction", "duration_ms"), (), "action")
        _require_choice(action["direction"], ("forward", "back"), "action direction")
        _require_int(action["duration_ms"], "action duration_ms", 80, duration_max)
        return "tilt"
    if op == "expression":
        _require_exact_keys(action, ("op", "expression", "duration_ms"), (), "action")
        _require_choice(action["expression"], ("blink", "brow1", "brow2"),
                        "action expression")
        _require_int(action["duration_ms"], "action duration_ms", 80, duration_max)
        return "blink"
    if op == "jump":
        _require_exact_keys(action, ("op",), (), "action")
        return "jump"
    if op == "flip":
        _require_exact_keys(action, ("op", "direction"), (), "action")
        _require_choice(action["direction"], ("front", "back"), "action direction")
        return "jump"
    if op == "zoom":
        _require_exact_keys(action, ("op", "direction", "duration_ms"), (), "action")
        _require_choice(action["direction"], ("in", "out"), "action direction")
        _require_int(action["duration_ms"], "action duration_ms", 80, duration_max)
        return "zoom"
    if op == "reset":
        _require_exact_keys(action, ("op", "target"), (), "action")
        _require_choice(action["target"], ("spin", "zoom"), "action target")
        return action["target"]
    if op == "reaction":
        _require_exact_keys(
            action, ("op", "reaction_id"), ("duration_ms", "intensity"), "action")
        _validate_identifier(action["reaction_id"], "reaction_id", 128)
        if action["reaction_id"] not in constraints["allowed_reaction_ids"]:
            raise BridgeError("decision reaction is not allowed by the room")
        if "duration_ms" in action and action["duration_ms"] is not None:
            _require_int(action["duration_ms"], "reaction duration_ms", 80, duration_max)
        if "intensity" in action and action["intensity"] is not None:
            if not _is_finite_number(action["intensity"]):
                raise BridgeError("reaction intensity must be a finite number")
            if action["intensity"] < 0 or action["intensity"] > 4:
                raise BridgeError("reaction intensity must be inside 0...4")
        return None
    raise BridgeError("decision contains an unknown action")


def _validate_room_context(value):
    _require_exact_keys(value, ("state", "title"), ("premise",), "context room")
    _validate_visible(value["state"], "context room state", 32)
    _validate_visible(value["title"], "context room title", 120)
    premise = value.get("premise")
    if premise is not None:
        if not isinstance(premise, str) or len(premise) > 500 or _has_forbidden_text(premise):
            raise BridgeError("context room premise is invalid")


def _validate_participant_context(value):
    _require_exact_keys(
        value, ("participant_id", "display_name", "pose", "status"),
        ("speaking",), "participant context")
    _validate_identifier(value["participant_id"], "participant_id", 128)
    _validate_visible(value["display_name"], "participant display_name", 60)
    _validate_visible(value["status"], "participant status", 32)
    speaking = value.get("speaking", False)
    if type(speaking) is not bool:
        raise BridgeError("participant speaking must be a boolean")
    pose = value["pose"]
    _require_exact_keys(
        pose, ("x", "depth", "face", "spin", "zoom"), (), "participant pose")
    for key in ("x", "depth", "spin", "zoom"):
        if not _is_finite_number(pose[key]):
            raise BridgeError("participant pose values must be finite numbers")
    _require_choice(pose["face"], ("left", "right"), "participant pose face")


def _validate_recent_event(value, basis_seq):
    _require_exact_keys(
        value, ("seq", "scene_time_ms", "kind"),
        ("participant_id", "text", "action"), "recent event")
    seq = _require_int(
        value["seq"], "recent event seq", minimum=0,
        maximum=(1 << 63) - 1)
    if seq > basis_seq:
        raise BridgeError("recent event seq exceeds context basis_seq")
    _require_int(
        value["scene_time_ms"], "recent event scene_time_ms", minimum=0,
        maximum=(1 << 63) - 1)
    _validate_visible(value["kind"], "recent event kind", 64)
    if value.get("participant_id") is not None:
        _validate_identifier(value["participant_id"], "recent event participant_id", 128)
    for key in ("text", "action"):
        if value.get(key) is not None:
            if not isinstance(value[key], str) or len(value[key]) > 512 \
                    or _has_forbidden_text(value[key]):
                raise BridgeError("recent event {} is invalid".format(key))


def _validate_constraints(value):
    _require_exact_keys(
        value,
        ("allowed_actions", "allowed_reaction_ids", "max_actions",
         "max_speech_chars", "max_action_ms"),
        (), "context constraints")
    actions = value["allowed_actions"]
    if not isinstance(actions, list) or len(actions) > len(KNOWN_ACTIONS):
        raise BridgeError("constraints allowed_actions is invalid")
    if any(not isinstance(item, str) or item not in KNOWN_ACTIONS for item in actions):
        raise BridgeError("constraints contains an unknown allowed action")
    if len(set(actions)) != len(actions):
        raise BridgeError("constraints contains duplicate allowed actions")
    reactions = value["allowed_reaction_ids"]
    if not isinstance(reactions, list) or len(reactions) > 32:
        raise BridgeError("constraints allowed_reaction_ids is invalid")
    for reaction_id in reactions:
        _validate_identifier(reaction_id, "allowed reaction_id", 128)
    if len(set(reactions)) != len(reactions):
        raise BridgeError("constraints contains duplicate reaction IDs")
    _require_int(value["max_actions"], "constraints max_actions", 0, 4)
    _require_int(value["max_speech_chars"], "constraints max_speech_chars", 0, 280)
    _require_int(value["max_action_ms"], "constraints max_action_ms", 80, 3000)


def _parse_join_receipt(result):
    _require_json_content_type(result.headers, "room admission receipt")
    value = _decode_json(result.body, "room admission receipt")
    _require_exact_keys(
        value, ("participant_id", "session_token", "seat"), ("room",),
        "room admission receipt")
    _validate_identifier(value["participant_id"], "participant_id", 128)
    _validate_bearer(value["session_token"], "room session token")
    seat = _require_int(value["seat"], "room seat", 1, 10)
    if "room" in value and not isinstance(value["room"], dict):
        raise BridgeError("room admission receipt contains an invalid room snapshot")
    return JoinReceipt(value["participant_id"], value["session_token"], seat)


def _room_status_error(result, operation):
    code = "http_error"
    message = "the room rejected {}".format(operation)
    if _is_json_content_type(result.headers):
        try:
            value = _decode_json(result.body, "room problem")
            _require_exact_keys(value, ("error",), (), "room problem")
            problem = value["error"]
            _require_exact_keys(problem, ("code", "message"), (), "room problem")
            if _is_safe_room_id(problem["code"]):
                code = problem["code"]
            if isinstance(problem["message"], str) and problem["message"] \
                    and len(problem["message"]) <= 512 \
                    and not _has_forbidden_text(problem["message"]):
                message = problem["message"]
        except BridgeError:
            pass
    return BridgeError(
        "room {} failed (HTTP {}, {}): {}".format(
            operation, result.status, code, message))


def _split_http_url(raw, label):
    if not isinstance(raw, str) or not raw or "\\" in raw or _has_forbidden_text(raw) \
            or any(character.isspace() for character in raw):
        raise BridgeError("{} must be a plain HTTP(S) URL".format(label))
    try:
        parts = urlsplit(raw)
        # Accessing port forces urllib to validate bracket and integer syntax.
        port = parts.port
    except ValueError:
        raise BridgeError("{} contains an invalid authority or port".format(label))
    if parts.scheme.lower() not in ("http", "https") or not parts.hostname:
        raise BridgeError("{} must use HTTP or HTTPS".format(label))
    if parts.scheme != parts.scheme.lower():
        raise BridgeError("{} scheme must be lowercase".format(label))
    if parts.username is not None or parts.password is not None:
        raise BridgeError("{} must not contain credentials".format(label))
    if parts.query or parts.fragment:
        raise BridgeError("{} must not contain a query or fragment".format(label))
    if port is not None and (port < 1 or port > 65535):
        raise BridgeError("{} contains an invalid port".format(label))
    return parts


def _normalized_netloc(parts):
    host = parts.hostname
    if ":" in host:
        rendered_host = "[{}]".format(host.lower())
    else:
        rendered_host = host.lower()
    return rendered_host + ((":" + str(parts.port)) if parts.port is not None else "")


def _decoded_path_segments(path, label):
    if not path.startswith("/"):
        raise BridgeError("{} must contain an absolute path".format(label))
    raw_segments = path.split("/")[1:]
    if raw_segments and raw_segments[-1] == "":
        raw_segments.pop()
    if not raw_segments or any(segment == "" for segment in raw_segments):
        raise BridgeError("{} contains an empty path segment".format(label))
    decoded = []
    for segment in raw_segments:
        index = 0
        while index < len(segment):
            if segment[index] == "%":
                if index + 2 >= len(segment) or segment[index + 1] not in HEX \
                        or segment[index + 2] not in HEX:
                    raise BridgeError("{} contains invalid percent encoding".format(label))
                index += 3
            else:
                index += 1
        try:
            decoded.append(unquote_to_bytes(segment).decode("utf-8", "strict"))
        except UnicodeDecodeError:
            raise BridgeError("{} path is not valid UTF-8".format(label))
    return decoded


def _is_safe_room_id(value):
    if not isinstance(value, str) or value in (".", ".."):
        return False
    try:
        return len(value.encode("utf-8", "strict")) <= 200 \
            and SAFE_ID_RE.match(value) is not None
    except UnicodeEncodeError:
        return False


def _read_regular_file(path, limit, private):
    path = os.fspath(Path(path).expanduser())
    flags = os.O_RDONLY
    flags |= getattr(os, "O_BINARY", 0)
    flags |= getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        before = os.lstat(path)
        if stat.S_ISLNK(before.st_mode):
            raise BridgeError("{} must not be a symbolic link".format(path))
        descriptor = os.open(path, flags)
    except BridgeError:
        raise
    except OSError as error:
        raise BridgeError("could not open {}: {}".format(path, _safe_reason(error)))
    try:
        current = os.fstat(descriptor)
        if not stat.S_ISREG(current.st_mode):
            raise BridgeError("{} must name a regular file".format(path))
        if (before.st_dev, before.st_ino) != (current.st_dev, current.st_ino):
            raise BridgeError("{} changed while it was being opened".format(path))
        if current.st_size > limit:
            raise BridgeError("{} exceeds the {}-byte limit".format(path, limit))
        if private and os.name == "posix":
            if stat.S_IMODE(current.st_mode) & 0o077:
                raise BridgeError(
                    "credentials file must not be accessible by group or other users; "
                    "run chmod 600 on it")
            if hasattr(os, "getuid") and current.st_uid != os.getuid():
                raise BridgeError("credentials file must be owned by the current user")
        with os.fdopen(descriptor, "rb", closefd=True) as handle:
            descriptor = -1
            data = handle.read(limit + 1)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if not data:
        raise BridgeError("{} cannot be empty".format(path))
    if len(data) > limit:
        raise BridgeError("{} exceeds the {}-byte limit".format(path, limit))
    return data


def _decode_json(data, label):
    try:
        text = data.decode("utf-8", "strict")
        value = json.loads(
            text,
            object_pairs_hook=_unique_object,
            parse_constant=_reject_json_constant,
            parse_float=_strict_json_float,
        )
        _reject_json_surrogates(value)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, TypeError,
            RecursionError) as error:
        del error
        raise BridgeError("{} is not strict UTF-8 JSON".format(label))
    if not isinstance(value, dict):
        raise BridgeError("{} must contain a JSON object".format(label))
    return value


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _reject_json_constant(value):
    del value
    raise ValueError("non-finite JSON number")


def _strict_json_float(value):
    parsed = float(value)
    if not math.isfinite(parsed):
        raise ValueError("non-finite JSON number")
    return parsed


def _reject_json_surrogates(value):
    pending = [value]
    while pending:
        item = pending.pop()
        if isinstance(item, str):
            if any(unicodedata.category(character) == "Cs" for character in item):
                raise ValueError("lone Unicode surrogate")
        elif isinstance(item, dict):
            pending.extend(item.keys())
            pending.extend(item.values())
        elif isinstance(item, list):
            pending.extend(item)


def _encode_json(value, limit, label):
    try:
        data = json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8", "strict")
    except (TypeError, ValueError, UnicodeEncodeError):
        raise BridgeError("{} could not be encoded as strict JSON".format(label))
    if len(data) > limit:
        raise BridgeError("{} exceeds the {}-byte limit".format(label, limit))
    return data


def _read_bounded(stream, headers, limit):
    if not isinstance(limit, int) or limit < 0:
        raise BridgeError("invalid HTTP response limit")
    raw_length = headers.get("content-length")
    if raw_length is not None:
        if not raw_length.isdigit():
            raise BridgeError("HTTP response has an invalid Content-Length")
        if int(raw_length) > limit:
            raise BridgeError("HTTP response exceeds the {}-byte limit".format(limit))
    data = stream.read(limit + 1)
    if len(data) > limit:
        raise BridgeError("HTTP response exceeds the {}-byte limit".format(limit))
    return data


def _header_values(headers, name):
    getter = getattr(headers, "get_all", None)
    if getter is not None:
        values = getter(name) or []
        return [str(value) for value in values]
    value = headers.get(name)
    if value is None:
        value = headers.get(name.lower())
    return [] if value is None else [str(value)]


def _require_json_content_type(headers, label):
    if not _is_json_content_type(headers):
        raise BridgeError("{} did not use application/json".format(label))


def _is_json_content_type(headers):
    raw = headers.get("content-type", "")
    media_type = raw.split(";", 1)[0].strip().lower()
    return media_type == "application/json" or media_type.endswith("+json")


def _require_exact_keys(value, required, optional, label):
    if not isinstance(value, dict):
        raise BridgeError("{} must be a JSON object".format(label))
    required_set = set(required)
    allowed = required_set | set(optional)
    missing = sorted(required_set - set(value))
    unknown = sorted(set(value) - allowed)
    if missing:
        raise BridgeError("{} is missing required fields".format(label))
    if unknown:
        raise BridgeError("{} contains unsupported fields".format(label))


def _validate_display_name(value):
    if not isinstance(value, str):
        raise BridgeError("--name must be text")
    normalized = value.strip()
    _validate_visible(normalized, "--name", 60)
    return normalized


def _validate_visible(value, label, maximum, byte_limit=False):
    if not isinstance(value, str) or not value or _has_forbidden_text(value):
        raise BridgeError("{} must be nonempty text without control characters".format(label))
    try:
        count = len(value.encode("utf-8", "strict")) if byte_limit else len(value)
    except UnicodeEncodeError:
        raise BridgeError("{} is not valid Unicode text".format(label))
    if count > maximum:
        raise BridgeError("{} exceeds its {}-character limit".format(label, maximum))


def _validate_identifier(value, label, maximum):
    _validate_visible(value, label, maximum)


def _validate_bearer(value, label):
    if not isinstance(value, str) or TOKEN_RE.match(value) is None:
        raise BridgeError("{} is malformed".format(label))


def _require_int(value, label, minimum=None, maximum=None):
    if type(value) is not int:
        raise BridgeError("{} must be an integer".format(label))
    if minimum is not None and value < minimum:
        raise BridgeError("{} is below its minimum".format(label))
    if maximum is not None and value > maximum:
        raise BridgeError("{} exceeds its maximum".format(label))
    return value


def _require_choice(value, choices, label):
    if not isinstance(value, str) or value not in choices:
        raise BridgeError("{} is not supported".format(label))


def _is_finite_number(value):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except (OverflowError, TypeError, ValueError):
        return False


def _has_forbidden_text(value):
    return any(unicodedata.category(character) in ("Cc", "Cf", "Cs")
               for character in value)


def _safe_text(value, maximum):
    text = str(value)
    return "".join(
        "\ufffd" if _has_forbidden_text(character) else character
        for character in text
    )[:maximum]


def _finish_retry_failure(failure):
    if isinstance(failure, HTTPResult):
        return failure
    raise failure


def _classified_transport_error(error):
    root = getattr(error, "reason", error) if isinstance(error, URLError) else error
    if isinstance(root, (ssl.SSLError, ssl.CertificateError)):
        return BridgeError("TLS request failed")
    if isinstance(root, socket.gaierror):
        if root.errno in TRANSIENT_GAI_CODES:
            return TransientNetworkError(
                "temporary DNS lookup failed: {}".format(_safe_reason(root)))
        return BridgeError("DNS lookup failed: {}".format(_safe_reason(root)))
    if isinstance(root, socket.herror):
        if root.errno in TRANSIENT_HERROR_CODES:
            return TransientNetworkError(
                "temporary DNS lookup failed: {}".format(_safe_reason(root)))
        return BridgeError("DNS lookup failed: {}".format(_safe_reason(root)))
    if isinstance(root, (
            socket.timeout,
            TimeoutError,
            ConnectionError,
            http.client.IncompleteRead,
            http.client.RemoteDisconnected,
    )):
        return TransientNetworkError(
            "transient network request failed: {}".format(_safe_reason(root)))
    if isinstance(root, (http.client.BadStatusLine, http.client.LineTooLong)):
        return BridgeError("malformed HTTP response")
    if isinstance(root, OSError) and root.errno in TRANSIENT_ERRNOS:
        return TransientNetworkError(
            "transient network request failed: {}".format(_safe_reason(root)))
    return BridgeError("network request failed: {}".format(_safe_reason(root)))


def _classified_response_read_error(error, status):
    classified = _classified_transport_error(error)
    if (isinstance(classified, TransientNetworkError)
            and not (200 <= status < 300)
            and status not in RETRYABLE_ROOM_STATUSES):
        return BridgeError(
            "HTTP {} response body could not be read".format(status))
    return classified


def _safe_reason(error):
    reason = getattr(error, "reason", None)
    if reason is None:
        reason = str(error)
    return _safe_text(reason, 256)


def _install_signal_handlers():
    previous = {}

    def stop(signum, frame):
        del signum, frame
        raise StopRequested()

    numbers = [signal.SIGINT]
    for name in ("SIGTERM", "SIGBREAK"):
        number = getattr(signal, name, None)
        if number is not None and number not in numbers:
            numbers.append(number)
    for number in numbers:
        try:
            previous[number] = signal.getsignal(number)
            signal.signal(number, stop)
        except (OSError, RuntimeError, ValueError):
            pass
    return previous


def _restore_signal_handlers(previous):
    for number, handler in previous.items():
        try:
            signal.signal(number, handler)
        except (OSError, RuntimeError, ValueError):
            pass


def build_parser():
    parser = argparse.ArgumentParser(
        description="Connect a Banny character and local AI to a Banny Live room.")
    parser.add_argument("room_url", help="Public /rooms/<id>/live or /v1/rooms/<id> URL")
    parser.add_argument("--agent", required=True,
                        help="AI origin; numeric loopback is required by default")
    parser.add_argument("--name", required=True, help="Participant display name")
    parser.add_argument("--character", required=True, metavar="AVATAR.JSON",
                        help="Strict avatar JSON downloaded from the room site")
    parser.add_argument("--credentials-file", metavar="FILE",
                        help="Private JSON containing identity, invite, and/or agent_token")
    parser.add_argument("--allow-remote-agent", action="store_true",
                        help="Allow an explicitly configured remote HTTPS AI origin")
    parser.add_argument("--json", action="store_true",
                        help="Write machine-readable ready/progress records")
    parser.add_argument("--version", action="version",
                        version="banny-live-bridge {}".format(VERSION))
    return parser


def main(argv=None, http_client=None):
    arguments = build_parser().parse_args(argv)
    reporter = Reporter(arguments.json)
    bridge = None
    clean_closed = False
    previous_handlers = _install_signal_handlers()
    try:
        endpoint = normalize_room_url(arguments.room_url)
        avatar = load_avatar(arguments.character)
        credentials = load_credentials(arguments.credentials_file) \
            if arguments.credentials_file else Credentials()
        bridge = Bridge(
            endpoint=endpoint,
            agent_url=arguments.agent,
            display_name=arguments.name,
            avatar=avatar,
            credentials=credentials,
            allow_remote_agent=arguments.allow_remote_agent,
            http=http_client,
            reporter=reporter,
        )
        receipt = bridge.join()
        reporter.ready(endpoint.room_id, receipt.participant_id, receipt.seat)
        clean_closed = bridge.run() == "closed"
        return 0
    except (StopRequested, KeyboardInterrupt):
        reporter.stopping()
        return 0
    except BridgeError as error:
        reporter.error(str(error))
        return 1
    finally:
        _restore_signal_handlers(previous_handlers)
        if bridge is not None and bridge.receipt is not None and not clean_closed:
            bridge.leave_best_effort()


if __name__ == "__main__":
    sys.exit(main())
