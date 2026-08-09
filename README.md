# LANMP — LAN multiplayer for BeamNG.drive

Drive together on your network: synced vehicles, nametags with live ping, player list, chat and
a server browser that finds games on your LAN by itself. One person runs the small C++ server,
everyone installs the mod.

No launcher, no Python, no MCP bridge during gameplay — the mod talks UDP straight from BeamNG
via LuaSocket.

## Status

Verified: the server builds and passes an 18-case UDP integration suite driven by fake clients
(handshake, register/login, bad-credential and rate-limit handling, join/leave, roster + ping,
vehicle spawn/despawn, position sequencing, input relay, chat throttling, malformed packets,
late-joiner world state, LAN discovery replies, discovery throttling). Lua and JS files are
syntax-checked.

**Not yet verified in-game.** The client half has not been run inside BeamNG.drive on this
machine, so nametag rendering, the dead-reckoning physics correction, the server browser and the
UI app are code-complete but unproven against a live engine. Expect to iterate on the first run.

## Install

### 1. Server (one machine, whoever is hosting)

The host runs the server on their own PC — there is no central service. Easiest path is the host
bundle: build the server, then

```
python tools/pack_host.py
```

which writes `dist/LANMP-Server.zip` containing `lanmp_server.exe`, a README and
**Launch Online Multiplayer Server Host.bat**. Unzip anywhere, double-click the launcher: it adds
the UDP firewall rule if it can, prints the addresses other players can type in, and starts the
server. Settings (name, port, player cap, map) are plain variables at the top of that .bat.

Building it once:

```
cd server
cmake -S . -B build -G "MinGW Makefiles"   # or your generator; MSVC works too
cmake --build build --config Release
```

Or run it by hand:

```
build/lanmp_server --name "My Server" --max-players 8
```

Options:

| flag | default | meaning |
| --- | --- | --- |
| `--port <n>` | 4144 | UDP port |
| `--users <file>` | users.txt | account database |
| `--name <text>` | LANMP Server | shown to clients |
| `--map <path>` | /levels/gridmap_v2/info.json | map everyone should load |
| `--max-players <n>` | 8 | player cap |
| `--tick <n>` | 30 | broadcast tick rate |
| `--closed` | off | disable open registration |
| `--verbose` | off | debug logging |

Allow UDP 4144 through the host's firewall. For play over the internet, forward UDP 4144 to the
host machine; the protocol tolerates NAT rebinding because clients are identified by session key,
not by address.

### 2. Mod (every player)

```
python tools/pack_mod.py
```

Copy `dist/LANMP.zip` into:

```
%LOCALAPPDATA%\BeamNG.drive\<version>\mods\
```

Start BeamNG, load any level, then open the **LANMP** app from the UI app editor
(Escape → UI Apps → drag LANMP onto the screen).

### 3. Play

1. Everyone loads the same map as the server (`--map`).
2. In the LANMP app, press **Refresh** and click the host's server in the list — or type the
   host's IP and port by hand if you are not on the same network.
3. First time: type a username and press **New account** — the server returns a PIN. Keep it.
4. Afterwards: username + PIN → **Connect**.
5. Spawn a car. Other players' cars appear with nametags showing name, ping and distance.

Chat and the player list (with per-player ping) are in the same app. The nametag checkbox
toggles tags off.

## Layout

```
server/    C++17 UDP server (no dependencies beyond the standard library + ws2_32)
mod/       the BeamNG mod: GE extensions, vehicle extensions, UI app
tests/     headless fake-client protocol suite (python tests/test_protocol.py)
tools/     pack_mod.py, pack_host.py, host/ (launcher + host instructions)
```

## How it works

* **Transport** — `mod/lua/ge/extensions/lanmp/network.lua` opens a nonblocking LuaSocket UDP
  socket and drains up to 256 datagrams per frame, so a dead server never stalls the game.
* **Auth** — every gameplay packet carries `playerId + sessionKey`; the source address alone is
  never trusted. PINs are stored salted and iteratively hashed, and register/login attempts are
  rate-limited per address.
* **Vehicle sync** — the owner samples position, orientation, linear and angular velocity plus
  acceleration and sends it with a sequence number. Remote copies live in vehicle Lua
  (`lanmpSyncVE`) and are dead-reckoned forward, corrected with cluster forces rather than
  teleported; teleporting is a last resort for severe divergence. Steering/throttle/brake/gear
  are relayed separately at 15 Hz.
* **Nametags** — drawn with the engine's debug text API, faded by distance, with live ping.
* **Server browser** — `discovery.lua` broadcasts a tiny probe on ports 4144-4147 from its own
  socket; servers answer with name, player count, map and version. Replies are matched by nonce so
  the listed ping is a real round trip, and servers throttle probes per source address to avoid
  being an amplification target. Broadcast does not cross subnets, so remote servers still need to
  be typed in (or joined over a VPN, which does carry broadcast).

## Security notes

The threat model is "people you invited on your LAN". PINs are transmitted over plain UDP, so do
not reuse a password you care about, and don't expose the port to the open internet without a
VPN. Hashing is salted iterative SHA-256, which is adequate here but is not a modern password KDF.
Discovery replies are unauthenticated by nature — they only reveal the server name, map and player
count, but a host who does not want to be listed should not run on a public network.

## Tests

```
cd server && cmake --build build
python tests/test_protocol.py
```

The suite starts the real server binary and speaks the real wire protocol over UDP.
