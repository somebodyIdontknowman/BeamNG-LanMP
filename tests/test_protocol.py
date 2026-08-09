"""Protocol level integration tests.

Starts the real lanmp_server binary and talks to it with fake UDP clients, so
these cover the wire format the Lua mod has to match, not a mock of it.

    python tests/test_protocol.py            (or: python -m unittest discover tests)
"""

import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

HELLO, HELLO_ACK = 0x01, 0x02
REGISTER, REGISTER_ACK = 0x03, 0x04
LOGIN, LOGIN_ACK, AUTH_NACK = 0x05, 0x06, 0x07
POS_UPDATE, POS_BROADCAST = 0x10, 0x11
INPUT_UPDATE, INPUT_BROADCAST = 0x12, 0x13
VEH_SPAWN, VEH_SPAWN_B = 0x20, 0x21
VEH_DESPAWN, VEH_DESPAWN_B = 0x22, 0x23
CHAT, CHAT_BROADCAST = 0x30, 0x31
DISCONNECT = 0x40
PING, PONG = 0x50, 0x51
PLAYER_JOIN, PLAYER_LEAVE, ROSTER = 0x60, 0x61, 0x62

PROTOCOL_VERSION = 2

REASON_BAD_CREDENTIALS = 1
REASON_UNKNOWN_USER = 2
REASON_USER_EXISTS = 3
REASON_RATE_LIMITED = 4


def server_binary():
    for candidate in (
        os.path.join(ROOT, "server", "build", "lanmp_server.exe"),
        os.path.join(ROOT, "server", "build", "lanmp_server"),
        os.path.join(ROOT, "server", "build", "Release", "lanmp_server.exe"),
    ):
        if os.path.exists(candidate):
            return candidate
    raise RuntimeError("lanmp_server not built; run cmake --build server/build first")


def wstr(s):
    data = s.encode("utf-8")
    return struct.pack("<H", len(data)) + data


class Reader:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def take(self, n):
        if self.p + n > len(self.d):
            raise AssertionError("packet truncated")
        out = self.d[self.p:self.p + n]
        self.p += n
        return out

    def u8(self):
        return self.take(1)[0]

    def u16(self):
        return struct.unpack("<H", self.take(2))[0]

    def u32(self):
        return struct.unpack("<I", self.take(4))[0]

    def f32(self):
        return struct.unpack("<f", self.take(4))[0]

    def string(self):
        return self.take(self.u16()).decode("utf-8", "replace")


class FakeClient:
    def __init__(self, port):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(0.4)
        self.addr = ("127.0.0.1", port)
        self.player_id = 0
        self.session_key = 0
        self.name = ""
        self.pending = []

    def close(self):
        if self.player_id:
            try:
                self.send(bytes([DISCONNECT]) + self.auth())
            except OSError:
                pass
            self.player_id = 0
        self.sock.close()

    def send(self, data):
        self.sock.sendto(data, self.addr)

    def auth(self):
        return struct.pack("<II", self.player_id, self.session_key)

    def recv_packets(self, timeout=0.35):
        """Drains everything that arrives within the timeout."""
        out = []
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.sock.settimeout(max(deadline - time.time(), 0.01))
            try:
                data, _ = self.sock.recvfrom(65535)
            except socket.timeout:
                break
            out.append((data[0], Reader(data[1:])))
        return out

    def wait_for(self, packet_type, timeout=1.0):
        for i, (t, r) in enumerate(self.pending):
            if t == packet_type:
                del self.pending[i]
                return r
        deadline = time.time() + timeout
        while time.time() < deadline:
            for t, r in self.recv_packets(0.2):
                if t == packet_type:
                    return r
        return None

    # -- handshake helpers ------------------------------------------------
    def hello(self):
        self.send(bytes([HELLO]) + struct.pack("<H", PROTOCOL_VERSION) + wstr("test"))
        return self.wait_for(HELLO_ACK)

    def register(self, name):
        self.send(bytes([REGISTER]) + wstr(name))
        return self.recv_packets()

    def login(self, name, pin):
        self.send(bytes([LOGIN]) + wstr(name) + wstr(pin))
        return self.recv_packets()

    def register_pin(self, name, tries=3):
        """Registers name and returns its PIN, retrying lost datagrams."""
        for _ in range(tries):
            for t, r in self.register(name):
                if t == REGISTER_ACK:
                    r.string()
                    return r.string()
                self.pending.append((t, r))
        raise AssertionError("no RegisterAck for %s" % name)

    def login_ok(self, name, pin, tries=3):
        for _ in range(tries):
            for t, r in self.login(name, pin):
                if t == LOGIN_ACK:
                    self.player_id = r.u32()
                    self.session_key = r.u32()
                else:
                    # Join-time world state arrives in the same burst; keep it
                    # so tests can still assert on it.
                    self.pending.append((t, r))
            if self.player_id:
                return True
        return False

    def join(self, name):
        """register + login, returns the account PIN."""
        self.name = name
        self.hello()
        pin = self.register_pin(name)
        assert self.login_ok(name, pin), "no LoginAck for %s" % name
        return pin

    def spawn_vehicle(self, veh_id, model="pickup", config="", plate="LANMP"):
        self.send(bytes([VEH_SPAWN]) + self.auth() + struct.pack("<I", veh_id)
                  + wstr(model) + wstr(config) + wstr(plate) + struct.pack("<I", 0))

    def send_pos(self, veh_id, seq, x=0.0):
        body = struct.pack("<IIf", veh_id, seq, 1.0)
        body += struct.pack("<3f", x, 0.0, 0.0)
        body += struct.pack("<4f", 0.0, 0.0, 0.0, 1.0)
        body += struct.pack("<3f", 0.0, 0.0, 0.0)
        body += struct.pack("<3f", 0.0, 0.0, 0.0)
        self.send(bytes([POS_UPDATE]) + self.auth() + body)


class ProtocolTest(unittest.TestCase):
    port = 0
    proc = None
    tmpdir = None
    log = None
    log_path = ""

    @classmethod
    def setUpClass(cls):
        cls.tmpdir = tempfile.mkdtemp(prefix="lanmp-test-")
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.bind(("127.0.0.1", 0))
        cls.port = probe.getsockname()[1]
        probe.close()

        # A pipe would fill up and stall the server once --verbose gets chatty.
        cls.log_path = os.path.join(cls.tmpdir, "server.log")
        cls.log = open(cls.log_path, "wb")
        cls.proc = subprocess.Popen(
            [server_binary(), "--port", str(cls.port), "--users",
             os.path.join(cls.tmpdir, "users.txt"), "--max-players", "32", "--verbose"],
            stdout=cls.log, stderr=subprocess.STDOUT)
        time.sleep(0.6)
        if cls.proc.poll() is not None:
            cls.log.close()
            with open(cls.log_path, "rb") as f:
                raise RuntimeError("server exited: " + f.read().decode(errors="replace"))

    @classmethod
    def tearDownClass(cls):
        if cls.proc and cls.proc.poll() is None:
            cls.proc.terminate()
            cls.proc.wait(timeout=5)
        if cls.log and not cls.log.closed:
            cls.log.close()

    def client(self):
        c = FakeClient(self.port)
        self.addCleanup(c.close)
        return c

    def expect(self, receiver, packet_type, resend, tries=3, timeout=0.8):
        """Waits for a packet, resending the trigger since UDP may drop it."""
        for _ in range(tries):
            r = receiver.wait_for(packet_type, timeout)
            if r is not None:
                return r
            resend()
        self.fail("never received packet type 0x%02X" % packet_type)

    # -- handshake --------------------------------------------------------

    def test_hello_reports_server_info(self):
        r = self.client().hello()
        self.assertIsNotNone(r, "no HelloAck")
        self.assertEqual(r.u16(), PROTOCOL_VERSION)
        self.assertTrue(len(r.string()) > 0)      # server name
        self.assertTrue(r.u8() > 0)               # max players
        self.assertTrue(r.u8() > 0)               # tick rate
        self.assertTrue(r.string().endswith(".json"))

    def test_register_then_duplicate_is_rejected(self):
        c = self.client()
        c.hello()
        self.assertEqual(len(c.register_pin("dupuser")), 6)

        other = self.client()
        other.hello()
        reasons = [r.u8() for t, r in other.register("dupuser") if t == AUTH_NACK]
        self.assertIn(REASON_USER_EXISTS, reasons)

    def test_login_requires_correct_pin(self):
        c = self.client()
        c.hello()
        pin = c.register_pin("pinuser")

        bad = self.client()
        reasons = [r.u8() for t, r in bad.login("pinuser", "000000") if t == AUTH_NACK]
        self.assertIn(REASON_BAD_CREDENTIALS, reasons)

        self.assertTrue(c.login_ok("pinuser", pin), "correct PIN was not accepted")

    def test_unknown_user_rejected(self):
        c = self.client()
        reasons = [r.u8() for t, r in c.login("ghost", "123456") if t == AUTH_NACK]
        self.assertIn(REASON_UNKNOWN_USER, reasons)

    def test_auth_attempts_are_rate_limited(self):
        c = self.client()
        seen = []
        for _ in range(8):
            seen += [r.u8() for t, r in c.login("ghost2", "123456") if t == AUTH_NACK]
        self.assertIn(REASON_RATE_LIMITED, seen)

    # -- session ----------------------------------------------------------

    def test_join_broadcasts_player_and_roster(self):
        a = self.client()
        a.join("alpha")
        b = self.client()
        b.join("bravo")

        joined = a.wait_for(PLAYER_JOIN, 2.0)
        self.assertIsNotNone(joined, "alpha never saw bravo join")
        self.assertEqual(joined.u32(), b.player_id)
        self.assertEqual(joined.string(), "bravo")

        # Rosters go out once a second, so the first one alpha sees can predate
        # bravo; wait for one that covers both.
        names, you = [], []
        deadline = time.time() + 4.0
        while time.time() < deadline and len(names) < 2:
            roster = a.wait_for(ROSTER, 2.0)
            self.assertIsNotNone(roster)
            names, you = [], []
            for _ in range(roster.u8()):
                roster.u32()
                names.append(roster.string())
                roster.u16()
                you.append(roster.u8())
        self.assertIn("alpha", names)
        self.assertIn("bravo", names)
        self.assertEqual(sum(you), 1)

    def test_gameplay_packets_need_a_valid_session_key(self):
        a = self.client()
        a.join("charlie")
        b = self.client()
        b.join("delta")
        b.spawn_vehicle(1)
        a.recv_packets()

        real_key = b.session_key
        b.session_key = real_key ^ 0xDEADBEEF
        b.send_pos(1, 10, x=5.0)
        self.assertIsNone(a.wait_for(POS_BROADCAST, 0.5),
                          "server relayed a position with a forged session key")

        b.session_key = real_key
        seq = [11]

        def resend():
            seq[0] += 1
            b.send_pos(1, seq[0], x=6.0)

        resend()
        self.expect(a, POS_BROADCAST, resend)

    def test_vehicle_lifecycle_and_position_sequencing(self):
        a = self.client()
        a.join("echo")
        b = self.client()
        b.join("foxtrot")

        b.spawn_vehicle(7, model="etk800", config="{}", plate="MP7")
        spawn = self.expect(a, VEH_SPAWN_B,
                            lambda: b.spawn_vehicle(7, model="etk800", config="{}", plate="MP7"))
        self.assertEqual(spawn.u32(), b.player_id)
        self.assertEqual(spawn.u32(), 7)
        self.assertEqual(spawn.string(), "etk800")

        seq = [100]

        def send_pos():
            seq[0] += 1
            b.send_pos(7, seq[0], x=1.0)

        b.send_pos(7, seq[0], x=1.0)
        self.expect(a, POS_BROADCAST, send_pos)

        b.send_pos(7, 50, x=99.0)     # stale
        self.assertIsNone(a.wait_for(POS_BROADCAST, 0.4), "stale position was relayed")

        send_pos()
        self.expect(a, POS_BROADCAST, send_pos)

        def despawn_vehicle():
            b.spawn_vehicle(7, model="etk800")
            b.send(bytes([VEH_DESPAWN]) + b.auth() + struct.pack("<I", 7))

        b.send(bytes([VEH_DESPAWN]) + b.auth() + struct.pack("<I", 7))
        despawn = self.expect(a, VEH_DESPAWN_B, despawn_vehicle, tries=4)
        self.assertEqual(despawn.u32(), b.player_id)
        self.assertEqual(despawn.u32(), 7)

    def test_position_for_unknown_vehicle_is_dropped(self):
        a = self.client()
        a.join("golf")
        b = self.client()
        b.join("hotel")
        b.send_pos(999, 1)
        self.assertIsNone(a.wait_for(POS_BROADCAST, 0.5))

    def test_new_player_receives_existing_world_state(self):
        a = self.client()
        a.join("india")
        a.spawn_vehicle(3, model="covet")
        time.sleep(0.2)

        b = self.client()
        b.join("juliet")
        spawn = b.wait_for(VEH_SPAWN_B, 2.0)
        if spawn is None:      # the join burst can be lost; a respawn re-announces it
            spawn = self.expect(b, VEH_SPAWN_B, lambda: a.spawn_vehicle(3, model="covet"))
        self.assertEqual(spawn.u32(), a.player_id)
        self.assertEqual(spawn.u32(), 3)
        self.assertEqual(spawn.string(), "covet")

    def test_inputs_are_forwarded(self):
        a = self.client()
        a.join("kilo")
        b = self.client()
        b.join("lima")
        b.spawn_vehicle(2)
        a.recv_packets()

        def send_inputs():
            b.send(bytes([INPUT_UPDATE]) + b.auth() + struct.pack("<I", 2) + bytes([2])
                   + bytes([1]) + struct.pack("<f", -0.5)
                   + bytes([2]) + struct.pack("<f", 1.0))

        send_inputs()
        got = self.expect(a, INPUT_BROADCAST, send_inputs)
        self.assertEqual(got.u32(), b.player_id)
        self.assertEqual(got.u32(), 2)
        self.assertEqual(got.u8(), 2)
        self.assertEqual(got.u8(), 1)
        self.assertAlmostEqual(got.f32(), -0.5, places=5)

    def test_chat_is_relayed_and_rate_limited(self):
        a = self.client()
        a.join("mike")
        b = self.client()
        b.join("november")
        a.recv_packets()

        for i in range(10):
            b.send(bytes([CHAT]) + b.auth() + wstr("msg%d" % i))
        time.sleep(0.4)
        messages = []
        for t, r in a.recv_packets(0.5):
            if t == CHAT_BROADCAST:
                r.u32()
                r.string()
                messages.append(r.string())
        self.assertGreater(len(messages), 0)
        self.assertLessEqual(len(messages), 5, "chat rate limit did not apply")
        self.assertEqual(messages[0], "msg0")

    def test_ping_round_trip(self):
        c = self.client()
        c.join("oscar")
        c.send(bytes([PING]) + c.auth() + struct.pack("<IfH", 42, 1.25, 33))
        pong = c.wait_for(PONG, 1.0)
        self.assertIsNotNone(pong)
        self.assertEqual(pong.u32(), 42)
        self.assertAlmostEqual(pong.f32(), 1.25, places=5)

        # The reported rtt should show up in the roster the others receive.
        other = self.client()
        other.join("papa")
        deadline = time.time() + 3.0
        found = None
        while time.time() < deadline and found is None:
            c.send(bytes([PING]) + c.auth() + struct.pack("<IfH", 43, 1.0, 33))
            roster = other.wait_for(ROSTER, 1.0)
            if not roster:
                continue
            for _ in range(roster.u8()):
                roster.u32()
                name = roster.string()
                ping = roster.u16()
                roster.u8()
                if name == "oscar" and ping == 33:
                    found = ping
        self.assertEqual(found, 33, "ping never propagated into the roster")

    def test_disconnect_notifies_others(self):
        a = self.client()
        a.join("quebec")
        b = self.client()
        b.join("romeo")
        a.recv_packets()

        b.send(bytes([DISCONNECT]) + b.auth())
        leave = a.wait_for(PLAYER_LEAVE, 2.0)
        self.assertIsNotNone(leave)
        self.assertEqual(leave.u32(), b.player_id)
        self.assertEqual(leave.string(), "romeo")

    # -- robustness -------------------------------------------------------

    def test_malformed_packets_do_not_kill_the_server(self):
        c = self.client()
        c.join("sierra")
        junk = [
            b"",
            bytes([POS_UPDATE]),
            bytes([POS_UPDATE]) + c.auth() + b"\x01\x02",
            bytes([VEH_SPAWN]) + c.auth() + struct.pack("<I", 1) + struct.pack("<H", 60000),
            bytes([CHAT]) + c.auth() + struct.pack("<H", 500) + b"x" * 3,
            bytes([0xFF]) * 40,
            os.urandom(1200),
        ]
        for payload in junk:
            c.send(payload)
        time.sleep(0.3)

        self.assertIsNone(self.proc.poll(), "server died on a malformed packet")
        c.send(bytes([PING]) + c.auth() + struct.pack("<IfH", 7, 0.0, 0))
        self.assertIsNotNone(c.wait_for(PONG, 1.5), "server stopped responding")


if __name__ == "__main__":
    unittest.main(verbosity=2)
