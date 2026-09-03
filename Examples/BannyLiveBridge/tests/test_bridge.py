import contextlib
from email.message import Message
import http.client
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import ssl
import stat
import tempfile
import unittest
from urllib.error import HTTPError, URLError


ROOT = Path(__file__).resolve().parents[3]
BRIDGE_PATH = (
    ROOT / "Sources" / "BannyLive" / "Resources" / "Web"
    / "banny-live-bridge.py"
)
SPEC = importlib.util.spec_from_file_location("banny_live_bridge", BRIDGE_PATH)
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


JSON_HEADERS = {"content-type": "application/json; charset=utf-8"}


def encoded(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")


def valid_context(request_id="request-1", basis_seq=1):
    participant = {
        "participant_id": "room-1-p1",
        "display_name": "Portable Bot",
        "pose": {
            "x": 0.5,
            "depth": 0,
            "face": "right",
            "spin": 0,
            "zoom": 1,
        },
        "status": "active",
        "speaking": False,
    }
    return {
        "protocol": bridge.PROTOCOL,
        "request_id": request_id,
        "room_id": "room-1",
        "participant_id": "room-1-p1",
        "basis_seq": basis_seq,
        "timeout_ms": 3000,
        "context": {
            "scene_time_ms": 1200,
            "room": {"state": "live", "title": "Test room", "premise": "Testing"},
            "self_state": participant,
            "cast": [],
            "recent_events": [],
            "constraints": {
                "allowed_actions": [
                    "move", "depth", "tilt", "expression", "jump", "flip",
                    "rotate", "zoom", "reset", "reaction",
                ],
                "allowed_reaction_ids": ["wave"],
                "max_actions": 4,
                "max_speech_chars": 280,
                "max_action_ms": 3000,
            },
        },
    }


class FakeHTTP:
    def __init__(self, steps):
        self.steps = list(steps)
        self.calls = []

    def request(self, method, url, **kwargs):
        self.calls.append((method, url, kwargs))
        if not self.steps:
            raise AssertionError("unexpected HTTP request: {} {}".format(method, url))
        expected_method, expected_suffix, result = self.steps.pop(0)
        if method != expected_method:
            raise AssertionError("expected {}, got {}".format(expected_method, method))
        if not url.endswith(expected_suffix):
            raise AssertionError("expected URL suffix {!r}, got {!r}".format(
                expected_suffix, url))
        if isinstance(result, BaseException):
            raise result
        if callable(result):
            result = result(method, url, kwargs)
        return result


class FakeClock:
    def __init__(self):
        self.value = 0.0
        self.delays = []

    def __call__(self):
        return self.value

    def sleep(self, seconds):
        self.delays.append(seconds)
        self.value += seconds

    def advance(self, seconds):
        self.value += seconds


def result(status, value=None, headers=None):
    body = b"" if value is None else encoded(value)
    return bridge.HTTPResult(status, headers or JSON_HEADERS, body)


class URLTests(unittest.TestCase):
    def test_normalizes_supported_room_routes(self):
        cases = [
            "http://127.0.0.1:7330/rooms/room-1",
            "http://127.0.0.1:7330/rooms/room-1/live",
            "http://127.0.0.1:7330/rooms/room-1/join",
            "http://127.0.0.1:7330/v1/rooms/room-1",
        ]
        for raw in cases:
            with self.subTest(raw=raw):
                endpoint = bridge.normalize_room_url(raw)
                self.assertEqual(endpoint.room_id, "room-1")
                self.assertEqual(
                    endpoint.api_url,
                    "http://127.0.0.1:7330/v1/rooms/room-1",
                )

        ipv6 = bridge.normalize_room_url("http://[::1]:7330/rooms/room-1/live")
        self.assertEqual(ipv6.api_url, "http://[::1]:7330/v1/rooms/room-1")

    def test_room_requires_https_away_from_numeric_loopback(self):
        rejected = [
            "http://localhost:7330/rooms/room-1/live",
            "http://rooms.example/rooms/room-1/live",
            "http://128.0.0.1/rooms/room-1/live",
        ]
        for raw in rejected:
            with self.subTest(raw=raw):
                with self.assertRaises(bridge.BridgeError):
                    bridge.normalize_room_url(raw)
        endpoint = bridge.normalize_room_url(
            "https://Rooms.Example:443/rooms/room-1/live")
        self.assertEqual(endpoint.api_url,
                         "https://rooms.example:443/v1/rooms/room-1")

    def test_room_rejects_ambiguous_or_secret_bearing_urls(self):
        rejected = [
            "https://user:secret@rooms.example/rooms/room-1/live",
            "https://rooms.example/rooms/room-1/live?token=secret",
            "https://rooms.example/rooms/room-1/control",
            "https://rooms.example/rooms/room-1/extra",
            "https://rooms.example/rooms/%GG/live",
            "https://rooms.example//rooms/room-1/live",
        ]
        for raw in rejected:
            with self.subTest(raw=raw):
                with self.assertRaises(bridge.BridgeError):
                    bridge.normalize_room_url(raw)

    def test_agent_is_numeric_loopback_by_default_and_remote_https_by_opt_in(self):
        self.assertEqual(
            bridge.normalize_agent_url("http://127.2.3.4:7331"),
            "http://127.2.3.4:7331/v1/decide",
        )
        self.assertEqual(
            bridge.normalize_agent_url("https://[::1]:7331/"),
            "https://[::1]:7331/v1/decide",
        )
        with self.assertRaises(bridge.BridgeError):
            bridge.normalize_agent_url("http://localhost:7331")
        with self.assertRaises(bridge.BridgeError):
            bridge.normalize_agent_url("https://agent.example")
        with self.assertRaises(bridge.BridgeError):
            bridge.normalize_agent_url(
                "http://agent.example", allow_remote=True)
        self.assertEqual(
            bridge.normalize_agent_url(
                "https://agent.example", allow_remote=True),
            "https://agent.example/v1/decide",
        )


class FileValidationTests(unittest.TestCase):
    def write_json(self, directory, name, value, mode=0o600):
        path = Path(directory) / name
        path.write_text(value, encoding="utf-8")
        if os.name == "posix":
            path.chmod(mode)
        return path

    def test_credentials_are_strict_private_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_json(
                directory,
                "credentials.json",
                '{"identity":"machine-a","invite":"invite-token",'
                '"agent_token":"agent-token"}',
            )
            credentials = bridge.load_credentials(path)
            self.assertEqual(credentials.identity, "machine-a")
            self.assertEqual(credentials.invite, "invite-token")
            self.assertEqual(credentials.agent_token, "agent-token")

            path.write_text('{"identity":"a","identity":"b"}', encoding="utf-8")
            with self.assertRaises(bridge.BridgeError):
                bridge.load_credentials(path)
            path.write_text('{"secret":"nope"}', encoding="utf-8")
            with self.assertRaises(bridge.BridgeError):
                bridge.load_credentials(path)

    @unittest.skipUnless(os.name == "posix", "POSIX permission bits only")
    def test_credentials_reject_group_or_world_access(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_json(directory, "credentials.json", "{}", mode=0o644)
            with self.assertRaisesRegex(bridge.BridgeError, "chmod 600"):
                bridge.load_credentials(path)

    def test_avatar_requires_exact_shape_and_basic_catalog_types(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_json(
                directory,
                "avatar.json",
                '{"body":"orange","eyes":"default","mouth":"default",'
                '"outfit":{"12":"club-beanie"}}',
            )
            avatar = bridge.load_avatar(path)
            self.assertEqual(avatar["outfit"], {"12": "club-beanie"})

            path.write_text(
                '{"body":"orange","eyes":"default","mouth":"default",'
                '"outfit":{},"agent_endpoint":"http://127.0.0.1"}',
                encoding="utf-8",
            )
            with self.assertRaises(bridge.BridgeError):
                bridge.load_avatar(path)
            path.write_text(
                '{"body":"blue","eyes":"default","mouth":"default","outfit":{}}',
                encoding="utf-8",
            )
            with self.assertRaises(bridge.BridgeError):
                bridge.load_avatar(path)

    @unittest.skipUnless(hasattr(os, "symlink"), "symbolic links unavailable")
    def test_json_files_reject_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            target = self.write_json(
                directory,
                "avatar-real.json",
                '{"body":"orange","eyes":"default","mouth":"default","outfit":{}}',
            )
            link = Path(directory) / "avatar.json"
            try:
                link.symlink_to(target)
            except OSError:
                self.skipTest("symbolic links unavailable to this user")
            with self.assertRaises(bridge.BridgeError):
                bridge.load_avatar(link)


class ProtocolValidationTests(unittest.TestCase):
    def test_context_and_correlated_decision_validate(self):
        context = bridge.validate_context(
            valid_context(), "room-1", "room-1-p1")
        decision = {
            "protocol": bridge.PROTOCOL,
            "request_id": "request-1",
            "intent_id": "intent-1",
            "say": "Hello from the portable bridge.",
            "actions": [
                {"op": "move", "direction": "left", "duration_ms": 320},
                {"op": "expression", "expression": "brow1", "duration_ms": 100},
            ],
            "request_after_ms": 1000,
        }
        self.assertIs(bridge.validate_decision(decision, context), decision)

    def test_decision_rejects_mismatch_unknown_fields_and_duplicate_groups(self):
        context = valid_context()
        cases = [
            {
                "protocol": bridge.PROTOCOL,
                "request_id": "wrong-request",
                "intent_id": "intent-1",
                "actions": [],
            },
            {
                "protocol": bridge.PROTOCOL,
                "request_id": "request-1",
                "intent_id": "intent-1",
                "actions": [],
                "target_actor": "someone-else",
            },
            {
                "protocol": bridge.PROTOCOL,
                "request_id": "request-1",
                "intent_id": "intent-1",
                "actions": [
                    {"op": "jump"},
                    {"op": "flip", "direction": "front"},
                ],
            },
        ]
        for decision in cases:
            with self.subTest(decision=decision):
                with self.assertRaises(bridge.BridgeError):
                    bridge.validate_decision(decision, context)

    def test_context_rejects_unknown_fields_and_wrong_participant(self):
        context = valid_context()
        context["surprise"] = True
        with self.assertRaises(bridge.BridgeError):
            bridge.validate_context(context, "room-1", "room-1-p1")

        context = valid_context()
        with self.assertRaises(bridge.BridgeError):
            bridge.validate_context(context, "room-1", "different-p1")

        context = valid_context()
        context["basis_seq"] = 1 << 63
        with self.assertRaises(bridge.BridgeError):
            bridge.validate_context(context, "room-1", "room-1-p1")

    def test_json_decoder_rejects_nested_duplicates_nonfinite_and_surrogates(self):
        payloads = [
            b'{"outer":{"key":1,"key":2}}',
            b'{"number":1e9999}',
            b'{"text":"\\ud800"}',
            b'{"number":NaN}',
        ]
        for payload in payloads:
            with self.subTest(payload=payload):
                with self.assertRaises(bridge.BridgeError):
                    bridge._decode_json(payload, "fixture")


class HTTPClientTests(unittest.TestCase):
    def test_bounded_reader_rejects_declared_and_streamed_oversize(self):
        with self.assertRaises(bridge.BridgeError):
            bridge._read_bounded(io.BytesIO(b"tiny"), {"content-length": "9"}, 8)
        with self.assertRaises(bridge.BridgeError):
            bridge._read_bounded(io.BytesIO(b"123456789"), {}, 8)
        self.assertEqual(
            bridge._read_bounded(io.BytesIO(b"12345678"), {}, 8),
            b"12345678",
        )

    def test_http_client_declines_redirect_without_following(self):
        headers = Message()
        headers["Content-Type"] = "text/plain"
        headers["Content-Length"] = "0"

        class RedirectingOpener:
            def open(self, request, timeout):
                del timeout
                raise HTTPError(
                    request.full_url, 302, "Found", headers, io.BytesIO(b""))

        client = bridge.HTTPClient(opener=RedirectingOpener())
        with self.assertRaisesRegex(bridge.BridgeError, "redirect"):
            client.request("GET", "https://rooms.example/v1/rooms/room-1")

    def test_http_client_rejects_oversize_request_before_open(self):
        class FailingOpener:
            def open(self, request, timeout):
                del request, timeout
                raise AssertionError("network should not be reached")

        client = bridge.HTTPClient(opener=FailingOpener())
        with self.assertRaisesRegex(bridge.BridgeError, "request exceeds"):
            client.request(
                "POST", "https://rooms.example/v1/rooms/room-1",
                body=b"12345", request_limit=4)

    def test_http_client_rejects_ambiguous_response_framing(self):
        class Response(io.BytesIO):
            def __init__(self, headers):
                super().__init__(b"")
                self.status = 200
                self.headers = headers

            def geturl(self):
                return "https://rooms.example/v1/rooms/room-1"

        class StaticOpener:
            def __init__(self, response):
                self.response = response

            def open(self, request, timeout):
                del request, timeout
                return self.response

        duplicate = Message()
        duplicate["Content-Length"] = "0"
        duplicate["Content-Length"] = "0"
        client = bridge.HTTPClient(StaticOpener(Response(duplicate)))
        with self.assertRaisesRegex(bridge.BridgeError, "multiple Content-Length"):
            client.request("GET", "https://rooms.example/v1/rooms/room-1")

        conflict = Message()
        conflict["Content-Length"] = "0"
        conflict["Transfer-Encoding"] = "chunked"
        client = bridge.HTTPClient(StaticOpener(Response(conflict)))
        with self.assertRaisesRegex(bridge.BridgeError, "combines"):
            client.request("GET", "https://rooms.example/v1/rooms/room-1")

    def test_transport_error_classification_separates_transient_from_tls(self):
        transient = [
            URLError(socket.gaierror(socket.EAI_AGAIN, "temporary DNS failure")),
            TimeoutError("timed out"),
            ConnectionResetError("reset"),
        ]
        for error in transient:
            with self.subTest(error=error):
                classified = bridge._classified_transport_error(error)
                self.assertIsInstance(classified, bridge.TransientNetworkError)

        terminal = bridge._classified_transport_error(
            URLError(ssl.SSLError("certificate verification failed")))
        self.assertIs(type(terminal), bridge.BridgeError)

    def test_only_temporary_dns_failures_are_retryable(self):
        temporary = [
            socket.gaierror(socket.EAI_AGAIN, "try again"),
            socket.gaierror(11002, "WSATRY_AGAIN"),
            socket.herror(2, "TRY_AGAIN"),
            socket.herror(11002, "WSATRY_AGAIN"),
        ]
        permanent = [
            socket.gaierror(getattr(socket, "EAI_NONAME", -2), "no name"),
            socket.gaierror(getattr(socket, "EAI_FAIL", -4), "failed"),
            socket.gaierror(11001, "WSAHOST_NOT_FOUND"),
            socket.herror(1, "HOST_NOT_FOUND"),
            socket.herror(3, "NO_RECOVERY"),
        ]
        for error in temporary:
            with self.subTest(temporary=error):
                self.assertIsInstance(
                    bridge._classified_transport_error(URLError(error)),
                    bridge.TransientNetworkError,
                )
        for error in permanent:
            with self.subTest(permanent=error):
                self.assertIs(
                    type(bridge._classified_transport_error(URLError(error))),
                    bridge.BridgeError,
                )

    def test_malformed_http_exceptions_are_terminal_bridge_errors(self):
        class RaisingOpener:
            def __init__(self, error):
                self.error = error
                self.calls = 0

            def open(self, request, timeout):
                del request, timeout
                self.calls += 1
                raise self.error

        malformed = [
            http.client.BadStatusLine("not-http"),
            http.client.LineTooLong("header line"),
        ]
        for error in malformed:
            with self.subTest(error=error):
                opener = RaisingOpener(error)
                client = bridge.HTTPClient(opener=opener)
                with self.assertRaises(bridge.BridgeError) as caught:
                    client.request(
                        "GET", "https://rooms.example/v1/rooms/room-1")
                self.assertIs(type(caught.exception), bridge.BridgeError)
                self.assertEqual(opener.calls, 1)

    def test_401_status_wins_without_reading_an_untrusted_error_body(self):
        headers = Message()
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = str(bridge.MAX_CONTEXT_BYTES + 1)

        class PoisonBody(io.BytesIO):
            def __init__(self, failure):
                super().__init__(b"truncated")
                self.failure = failure
                self.reads = 0

            def read(self, size=-1):
                del size
                self.reads += 1
                raise self.failure

        class StatusOpener:
            def __init__(self, status, failure, response_headers=headers):
                self.status = status
                self.body = PoisonBody(failure)
                self.calls = 0
                self.headers = response_headers

            def open(self, request, timeout):
                del timeout
                self.calls += 1
                raise HTTPError(
                    request.full_url, self.status, "failure", self.headers,
                    self.body)

        failures = [
            socket.timeout("body stalled"),
            http.client.IncompleteRead(b"partial", 10),
            OSError("body failed"),
        ]
        for failure in failures:
            with self.subTest(failure=failure):
                opener = StatusOpener(401, failure)
                client = bridge.HTTPClient(opener=opener)
                response = client.request(
                    "GET", "https://rooms.example/v1/rooms/room-1")
                self.assertEqual(response.status, 401)
                self.assertEqual(response.body, b"")
                self.assertEqual(opener.calls, 1)
                self.assertEqual(opener.body.reads, 0)

        retry_headers = Message()
        retry_headers["Content-Length"] = "1"
        client = bridge.HTTPClient(opener=StatusOpener(
            503, socket.timeout("body stalled"), retry_headers))
        with self.assertRaises(bridge.TransientNetworkError):
            client.request("GET", "https://rooms.example/v1/rooms/room-1")


class PollingTests(unittest.TestCase):
    def make_bridge(self, fake, reporter=None, clock=None):
        clock = clock or FakeClock()
        return bridge.Bridge(
            endpoint=bridge.normalize_room_url(
                "http://127.0.0.1:7330/rooms/room-1/live"),
            agent_url="http://127.0.0.1:7331",
            display_name="Portable Bot",
            avatar={
                "body": "orange", "eyes": "default",
                "mouth": "default", "outfit": {},
            },
            credentials=bridge.Credentials(),
            http=fake,
            reporter=reporter or bridge.Reporter(
                stdout=io.StringIO(), stderr=io.StringIO()),
            empty_poll_delay=0,
            sleeper=clock.sleep,
            clock=clock,
        )

    def join_receipt(self):
        return {
            "participant_id": "room-1-p1",
            "session_token": "session-token",
            "seat": 1,
            "room": {},
        }

    def test_local_agent_error_submits_correlated_noop_then_terminal_401_is_clean(self):
        fake = FakeHTTP([
            ("POST", "/v1/rooms/room-1/join", result(201, self.join_receipt())),
            ("GET", "/v1/rooms/room-1/decisions/next", result(200, valid_context())),
            ("POST", "/v1/decide", result(500, {"error": "offline"})),
            ("POST", "/v1/rooms/room-1/decisions/request-1", result(200, {})),
            ("GET", "/v1/rooms/room-1/decisions/next?after=1", result(401)),
        ])
        output = io.StringIO()
        errors = io.StringIO()
        runtime = self.make_bridge(
            fake, bridge.Reporter(stdout=output, stderr=errors))
        runtime.join()
        self.assertEqual(runtime.run(), "closed")
        submitted = json.loads(fake.calls[3][2]["body"].decode("utf-8"))
        self.assertEqual(submitted["protocol"], bridge.PROTOCOL)
        self.assertEqual(submitted["request_id"], "request-1")
        self.assertTrue(submitted["intent_id"].startswith("bridge-skip-"))
        self.assertEqual(submitted["actions"], [])
        self.assertIn("skipped request request-1", errors.getvalue())
        self.assertIn("room bridge closed", output.getvalue())
        self.assertFalse(fake.steps)

    def test_successful_correlated_decision_is_submitted(self):
        decision = {
            "protocol": bridge.PROTOCOL,
            "request_id": "request-1",
            "intent_id": "intent-1",
            "actions": [{"op": "jump"}],
        }
        fake = FakeHTTP([
            ("POST", "/v1/rooms/room-1/join", result(201, self.join_receipt())),
            ("GET", "/v1/rooms/room-1/decisions/next", result(200, valid_context())),
            ("POST", "/v1/decide", result(200, decision)),
            ("POST", "/v1/rooms/room-1/decisions/request-1", result(401)),
        ])
        runtime = self.make_bridge(fake)
        runtime.join()
        self.assertEqual(runtime.run(), "closed")
        submitted = json.loads(fake.calls[3][2]["body"].decode("utf-8"))
        self.assertEqual(submitted, decision)

    def test_leave_uses_bearer_and_zero_length_body(self):
        fake = FakeHTTP([
            ("POST", "/v1/rooms/room-1/join", result(201, self.join_receipt())),
            ("POST", "/v1/rooms/room-1/leave", result(200, {})),
        ])
        runtime = self.make_bridge(fake)
        runtime.join()
        runtime.leave()
        kwargs = fake.calls[1][2]
        self.assertEqual(kwargs["bearer"], "session-token")
        self.assertEqual(kwargs["body"], b"")

    def test_cli_terminal_401_after_admission_exits_zero(self):
        fake = FakeHTTP([
            ("POST", "/v1/rooms/room-1/join", result(201, self.join_receipt())),
            ("GET", "/v1/rooms/room-1/decisions/next", result(401)),
        ])
        with tempfile.TemporaryDirectory() as directory:
            avatar = Path(directory) / "avatar.json"
            avatar.write_text(
                '{"body":"orange","eyes":"default","mouth":"default","outfit":{}}',
                encoding="utf-8",
            )
            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = bridge.main([
                    "http://127.0.0.1:7330/rooms/room-1/live",
                    "--agent", "http://127.0.0.1:7331",
                    "--name", "Portable Bot",
                    "--character", str(avatar),
                    "--json",
                ], http_client=fake)
        self.assertEqual(code, 0)
        ready = json.loads(stdout.getvalue().splitlines()[0])
        self.assertEqual(ready["operation"], "room_join")
        self.assertEqual(stderr.getvalue(), "")

    def test_unreadable_401_body_cleanly_closes_poll_and_submit(self):
        headers = Message()
        headers["Content-Length"] = str(bridge.MAX_CONTEXT_BYTES + 1)

        class PoisonBody(io.BytesIO):
            def __init__(self):
                super().__init__(b"truncated")
                self.reads = 0

            def read(self, size=-1):
                del size
                self.reads += 1
                raise socket.timeout("must not read a 401 body")

        class UnauthorizedOpener:
            def __init__(self):
                self.calls = 0
                self.body = PoisonBody()

            def open(self, request, timeout):
                del timeout
                self.calls += 1
                raise HTTPError(
                    request.full_url, 401, "Unauthorized", headers, self.body)

        for operation in ("poll", "submit"):
            with self.subTest(operation=operation):
                opener = UnauthorizedOpener()
                clock = FakeClock()
                runtime = self.make_bridge(
                    bridge.HTTPClient(opener=opener), clock=clock)
                runtime.receipt = bridge.JoinReceipt(
                    "room-1-p1", "session-token", 1)
                if operation == "poll":
                    self.assertEqual(runtime.run(), "closed")
                else:
                    decision = {
                        "protocol": bridge.PROTOCOL,
                        "request_id": "request-1",
                        "intent_id": "intent-1",
                        "actions": [],
                    }
                    with self.assertRaises(bridge.SessionClosed):
                        runtime._submit(decision, valid_context(), 0.0)
                self.assertEqual(opener.calls, 1)
                self.assertEqual(opener.body.reads, 0)
                self.assertEqual(clock.delays, [])

    def test_permanent_dns_and_malformed_http_never_retry_poll(self):
        class RaisingOpener:
            def __init__(self, error):
                self.error = error
                self.calls = 0

            def open(self, request, timeout):
                del request, timeout
                self.calls += 1
                raise self.error

        errors = [
            URLError(socket.gaierror(
                getattr(socket, "EAI_NONAME", -2), "no such host")),
            URLError(socket.gaierror(11001, "WSAHOST_NOT_FOUND")),
            http.client.BadStatusLine("not-http"),
            http.client.LineTooLong("header line"),
        ]
        for error in errors:
            with self.subTest(error=error):
                opener = RaisingOpener(error)
                clock = FakeClock()
                runtime = self.make_bridge(
                    bridge.HTTPClient(opener=opener), clock=clock)
                runtime.receipt = bridge.JoinReceipt(
                    "room-1-p1", "session-token", 1)
                with self.assertRaises(bridge.BridgeError) as caught:
                    runtime._poll(None)
                self.assertIs(type(caught.exception), bridge.BridgeError)
                self.assertEqual(opener.calls, 1)
                self.assertEqual(clock.delays, [])

    def test_poll_retries_503_with_150_300ms_backoff_and_shared_budget(self):
        fake = FakeHTTP([
            ("POST", "/v1/rooms/room-1/join", result(201, self.join_receipt())),
            ("GET", "/v1/rooms/room-1/decisions/next", result(503)),
            ("GET", "/v1/rooms/room-1/decisions/next", result(503)),
            ("GET", "/v1/rooms/room-1/decisions/next", result(200, valid_context())),
        ])
        clock = FakeClock()
        runtime = self.make_bridge(fake, clock=clock)
        runtime.join()
        context = runtime._poll(None)

        self.assertEqual(context["basis_seq"], 1)
        self.assertEqual(clock.delays, [0.150, 0.300])
        timeouts = [call[2]["timeout"] for call in fake.calls[1:]]
        self.assertAlmostEqual(timeouts[0], 11.516666, places=5)
        self.assertAlmostEqual(timeouts[1], 17.275, places=5)
        self.assertAlmostEqual(timeouts[2], 34.55, places=5)

    def test_submit_retries_transient_and_502_with_exact_same_bytes(self):
        decision = {
            "protocol": bridge.PROTOCOL,
            "request_id": "request-1",
            "intent_id": "intent-1",
            "actions": [{"op": "jump"}],
        }
        fake = FakeHTTP([
            ("POST", "/v1/rooms/room-1/join", result(201, self.join_receipt())),
            ("GET", "/v1/rooms/room-1/decisions/next", result(200, valid_context())),
            ("POST", "/v1/decide", result(200, decision)),
            ("POST", "/v1/rooms/room-1/decisions/request-1",
             bridge.TransientNetworkError("connection reset")),
            ("POST", "/v1/rooms/room-1/decisions/request-1", result(502)),
            ("POST", "/v1/rooms/room-1/decisions/request-1", result(202, {})),
            ("GET", "/v1/rooms/room-1/decisions/next?after=1", result(401)),
        ])
        clock = FakeClock()
        runtime = self.make_bridge(fake, clock=clock)
        runtime.join()
        self.assertEqual(runtime.run(), "closed")

        submissions = fake.calls[3:6]
        self.assertEqual(clock.delays, [0.050, 0.100])
        self.assertEqual(len({call[2]["body"] for call in submissions}), 1)
        self.assertTrue(all(call[1].endswith("/decisions/request-1")
                            for call in submissions))
        timeouts = [call[2]["timeout"] for call in submissions]
        self.assertAlmostEqual(timeouts[0], 0.95, places=6)
        self.assertAlmostEqual(timeouts[1], 1.425, places=6)
        self.assertAlmostEqual(timeouts[2], 2.85, places=6)

    def test_poll_stops_after_three_attempts(self):
        fake = FakeHTTP([
            ("POST", "/v1/rooms/room-1/join", result(201, self.join_receipt())),
            ("GET", "/v1/rooms/room-1/decisions/next", result(504)),
            ("GET", "/v1/rooms/room-1/decisions/next", result(504)),
            ("GET", "/v1/rooms/room-1/decisions/next", result(504)),
            ("GET", "/v1/rooms/room-1/decisions/next", result(204)),
        ])
        clock = FakeClock()
        runtime = self.make_bridge(fake, clock=clock)
        runtime.join()
        with self.assertRaises(bridge.BridgeError):
            runtime._poll(None)
        self.assertEqual(len(fake.calls), 4)
        self.assertEqual(clock.delays, [0.150, 0.300])
        self.assertEqual(len(fake.steps), 1)

    def test_poll_does_not_retry_terminal_or_malformed_failures(self):
        terminal_failures = [
            result(400, {"error": {"code": "bad_request", "message": "bad"}}),
            bridge.BridgeError("HTTP redirects are not allowed"),
            bridge.BridgeError("HTTP response exceeds the limit"),
            bridge.BridgeError("TLS request failed"),
            result(200, {}),
        ]
        for failure in terminal_failures:
            with self.subTest(failure=failure):
                fake = FakeHTTP([
                    ("POST", "/v1/rooms/room-1/join",
                     result(201, self.join_receipt())),
                    ("GET", "/v1/rooms/room-1/decisions/next", failure),
                    ("GET", "/v1/rooms/room-1/decisions/next", result(204)),
                ])
                clock = FakeClock()
                runtime = self.make_bridge(fake, clock=clock)
                runtime.join()
                with self.assertRaises(bridge.BridgeError):
                    runtime._poll(None)
                self.assertEqual(len(fake.calls), 2)
                self.assertEqual(clock.delays, [])

    def test_join_leave_and_local_agent_are_never_retried(self):
        join_fake = FakeHTTP([
            ("POST", "/v1/rooms/room-1/join", result(503)),
            ("POST", "/v1/rooms/room-1/join", result(201, self.join_receipt())),
        ])
        with self.assertRaises(bridge.BridgeError):
            self.make_bridge(join_fake).join()
        self.assertEqual(len(join_fake.calls), 1)

        leave_fake = FakeHTTP([
            ("POST", "/v1/rooms/room-1/join", result(201, self.join_receipt())),
            ("POST", "/v1/rooms/room-1/leave", result(503)),
            ("POST", "/v1/rooms/room-1/leave", result(200, {})),
        ])
        runtime = self.make_bridge(leave_fake)
        runtime.join()
        with self.assertRaises(bridge.BridgeError):
            runtime.leave()
        self.assertEqual(len(leave_fake.calls), 2)

        agent_fake = FakeHTTP([
            ("POST", "/v1/rooms/room-1/join", result(201, self.join_receipt())),
            ("GET", "/v1/rooms/room-1/decisions/next", result(200, valid_context())),
            ("POST", "/v1/decide", bridge.TransientNetworkError("agent offline")),
            ("POST", "/v1/rooms/room-1/decisions/request-1", result(202, {})),
            ("GET", "/v1/rooms/room-1/decisions/next?after=1", result(401)),
        ])
        runtime = self.make_bridge(agent_fake)
        runtime.join()
        self.assertEqual(runtime.run(), "closed")
        self.assertEqual(sum(call[1].endswith("/v1/decide")
                             for call in agent_fake.calls), 1)

    def test_submit_uses_only_remaining_context_deadline(self):
        clock = FakeClock()

        def delayed_decision(method, url, kwargs):
            del method, url, kwargs
            clock.advance(2.80)
            return result(200, {
                "protocol": bridge.PROTOCOL,
                "request_id": "request-1",
                "intent_id": "intent-1",
                "actions": [],
            })

        fake = FakeHTTP([
            ("POST", "/v1/rooms/room-1/join", result(201, self.join_receipt())),
            ("GET", "/v1/rooms/room-1/decisions/next", result(200, valid_context())),
            ("POST", "/v1/decide", delayed_decision),
            ("POST", "/v1/rooms/room-1/decisions/request-1", result(503)),
            ("POST", "/v1/rooms/room-1/decisions/request-1", result(202, {})),
            ("GET", "/v1/rooms/room-1/decisions/next?after=1", result(401)),
        ])
        runtime = self.make_bridge(fake, clock=clock)
        runtime.join()
        self.assertEqual(runtime.run(), "closed")
        submissions = fake.calls[3:5]
        self.assertEqual(clock.delays, [0.050])
        self.assertAlmostEqual(submissions[0][2]["timeout"], 1 / 60, places=5)
        self.assertAlmostEqual(submissions[1][2]["timeout"], 0.025, places=5)

    def test_submit_carries_the_original_absolute_context_deadline(self):
        clock = FakeClock()
        clock.value = 2.75
        runtime = self.make_bridge(FakeHTTP([]), clock=clock)
        runtime.receipt = bridge.JoinReceipt(
            "room-1-p1", "session-token", 1)
        captured = {}

        def capture_retry(method, url, **options):
            captured["method"] = method
            captured["url"] = url
            captured.update(options)
            clock.advance(0.20)
            return result(202, {})

        runtime._room_request_with_retry = capture_retry
        decision = {
            "protocol": bridge.PROTOCOL,
            "request_id": "request-1",
            "intent_id": "intent-1",
            "actions": [],
        }
        runtime._submit(decision, valid_context(), decision_started_at=0.0)

        self.assertEqual(captured["method"], "POST")
        self.assertEqual(captured["deadline"], 3.0)
        self.assertLessEqual(captured["deadline"], 3.0)
        self.assertGreater(clock.value, captured["deadline"] - 0.10)

    def test_retry_is_suppressed_when_backoff_crosses_poll_deadline(self):
        clock = FakeClock()

        def almost_expired(method, url, kwargs):
            del method, url, kwargs
            clock.advance(34.90)
            return result(503)

        fake = FakeHTTP([
            ("POST", "/v1/rooms/room-1/join", result(201, self.join_receipt())),
            ("GET", "/v1/rooms/room-1/decisions/next", almost_expired),
            ("GET", "/v1/rooms/room-1/decisions/next", result(204)),
        ])
        runtime = self.make_bridge(fake, clock=clock)
        runtime.join()
        with self.assertRaises(bridge.BridgeError):
            runtime._poll(None)
        self.assertEqual(len(fake.calls), 2)
        self.assertEqual(clock.delays, [])


if __name__ == "__main__":
    unittest.main()
