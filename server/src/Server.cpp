#include "Server.h"

#include "Logger.h"
#include "Util.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>

namespace lanmp {
namespace {

constexpr uint64_t kClientTimeoutMs   = 10000;
constexpr uint64_t kRosterIntervalMs  = 1000;
constexpr uint32_t kChatPerWindow     = 5;
constexpr uint64_t kChatWindowMs      = 5000;
constexpr size_t   kMaxVehiclesPerPlayer = 8;
constexpr size_t   kMaxConfigBytes    = 48000;
constexpr size_t   kMaxChatBytes      = 300;

#ifdef _WIN32
struct WsaInit {
    WsaInit() { WSADATA d; WSAStartup(MAKEWORD(2, 2), &d); }
    ~WsaInit() { WSACleanup(); }
} g_wsa;
#endif

bool finite3(float a, float b, float c) {
    return std::isfinite(a) && std::isfinite(b) && std::isfinite(c);
}

uint32_t random_u32() {
    static std::mt19937_64 gen(std::random_device{}() ^ now_ms());
    return static_cast<uint32_t>(gen() >> 16);
}

// Newer-than test that tolerates u32 wraparound.
bool seq_newer(uint32_t candidate, uint32_t current) {
    return static_cast<int32_t>(candidate - current) > 0;
}

}  // namespace

Server::Server(ServerConfig cfg) : cfg_(std::move(cfg)), auth_(cfg_.users_file) {}

Server::~Server() { close_socket(); }

std::string Server::make_addr_key(const sockaddr_in& a) {
    char ip[INET_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET, &a.sin_addr, ip, sizeof(ip));
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%s:%u", ip, ntohs(a.sin_port));
    return buf;
}

bool Server::init() {
    sock_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock_ == LANMP_INVALID_SOCK) {
        LOG_ERROR("socket() failed");
        return false;
    }

    int yes = 1;
    setsockopt(sock_, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&yes), sizeof(yes));

    sockaddr_in bind_addr{};
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    bind_addr.sin_port = htons(cfg_.port);

    if (bind(sock_, reinterpret_cast<sockaddr*>(&bind_addr), sizeof(bind_addr)) < 0) {
        LOG_ERROR("bind() failed on port %u", cfg_.port);
        close_socket();
        return false;
    }

    LOG_INFO("%s listening on UDP %u (map %s, max %u players)", cfg_.server_name.c_str(), cfg_.port,
             cfg_.map.c_str(), cfg_.max_players);
    return true;
}

void Server::close_socket() {
    if (sock_ != LANMP_INVALID_SOCK) {
#ifdef _WIN32
        closesocket(sock_);
#else
        close(sock_);
#endif
        sock_ = LANMP_INVALID_SOCK;
    }
}

void Server::poll(int timeout_ms) {
#ifdef _WIN32
    DWORD ms = static_cast<DWORD>(timeout_ms);
    setsockopt(sock_, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&ms), sizeof(ms));
#else
    timeval tv{timeout_ms / 1000, (timeout_ms % 1000) * 1000};
    setsockopt(sock_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
#endif

    static std::vector<uint8_t> buf(kMaxDatagram);
    sockaddr_in from{};
#ifdef _WIN32
    int fromlen = sizeof(from);
#else
    socklen_t fromlen = sizeof(from);
#endif
    int n = recvfrom(sock_, reinterpret_cast<char*>(buf.data()), static_cast<int>(buf.size()), 0,
                     reinterpret_cast<sockaddr*>(&from), &fromlen);
    if (n > 0) {
        try {
            handle_datagram(buf.data(), static_cast<size_t>(n), from);
        } catch (const std::exception& e) {
            LOG_WARN("Malformed packet from %s: %s", make_addr_key(from).c_str(), e.what());
        }
    }

    uint64_t t = now_ms();
    if (t - last_timeout_check_ms_ > 1000) {
        check_timeouts();
        last_timeout_check_ms_ = t;
    }
    if (t - last_roster_ms_ > kRosterIntervalMs) {
        broadcast_roster();
        last_roster_ms_ = t;
    }
}

int Server::run() {
    if (!init()) return 1;
    for (;;) poll(100);
}

void Server::send_raw(const sockaddr_in& to, const std::vector<uint8_t>& pkt) {
    sendto(sock_, reinterpret_cast<const char*>(pkt.data()), static_cast<int>(pkt.size()), 0,
           reinterpret_cast<const sockaddr*>(&to), sizeof(to));
}

void Server::send_to(const Client& c, const Writer& w) { send_raw(c.addr, w.data()); }

void Server::broadcast(const Writer& w, const Client* except) {
    for (auto& kv : clients_) {
        if (except && kv.second.id == except->id) continue;
        send_raw(kv.second.addr, w.data());
    }
}

void Server::send_auth_nack(const sockaddr_in& to, AuthReason reason, const std::string& msg) {
    Writer w(Type::AuthNack);
    w.u8(static_cast<uint8_t>(reason));
    w.str(msg);
    send_raw(to, w.data());
}

Client* Server::client_by_id(uint32_t id) {
    auto it = clients_.find(id);
    return it == clients_.end() ? nullptr : &it->second;
}

Client* Server::client_by_name(const std::string& name) {
    for (auto& kv : clients_) {
        if (kv.second.name == name) return &kv.second;
    }
    return nullptr;
}

// Every gameplay packet carries {playerId, sessionKey}. The key is what proves
// identity: the source address is only used as a hint and is allowed to change
// (NAT rebinding), which also means spoofing an address is not enough.
Client* Server::authenticate(Reader& r, const sockaddr_in& from) {
    uint32_t pid = r.u32();
    uint32_t key = r.u32();
    Client* c = client_by_id(pid);
    if (!c || c->session_key != key) return nullptr;

    std::string key_str = make_addr_key(from);
    if (key_str != c->addr_key) {
        LOG_INFO("Player '%s' moved from %s to %s", c->name.c_str(), c->addr_key.c_str(),
                 key_str.c_str());
        c->addr = from;
        c->addr_key = key_str;
    }
    c->last_recv_ms = now_ms();
    return c;
}

void Server::handle_datagram(const uint8_t* data, size_t len, const sockaddr_in& from) {
    Reader r(data, len);
    Type t = r.type();

    switch (t) {
        case Type::Hello:    on_hello(r, from); return;
        case Type::Register: on_register(r, from); return;
        case Type::Login:    on_login(r, from); return;
        default: break;
    }

    Client* c = authenticate(r, from);
    if (!c) {
        LOG_DEBUG("Unauthenticated packet type 0x%02X from %s", static_cast<unsigned>(t),
                  make_addr_key(from).c_str());
        return;
    }

    switch (t) {
        case Type::PosUpdate:      on_pos_update(*c, r); break;
        case Type::InputUpdate:    on_input_update(*c, r, data, len); break;
        case Type::GearUpdate:     on_gear_update(*c, r); break;
        case Type::VehicleSpawn:   on_vehicle_spawn(*c, r); break;
        case Type::VehicleDespawn: on_vehicle_despawn(*c, r); break;
        case Type::VehicleReset:   on_vehicle_reset(*c, r); break;
        case Type::Chat:           on_chat(*c, r); break;
        case Type::Ping:           on_ping(*c, r); break;
        case Type::Disconnect:     drop_client(c->id, "left the server"); break;
        default:
            LOG_DEBUG("Unhandled packet type 0x%02X", static_cast<unsigned>(t));
            break;
    }
}

void Server::on_hello(Reader& r, const sockaddr_in& from) {
    uint16_t version = r.u16();
    Writer w(Type::HelloAck);
    w.u16(kProtocolVersion);
    w.str(cfg_.server_name);
    w.u8(cfg_.max_players);
    w.u8(cfg_.tick_rate);
    w.str(cfg_.map);
    w.u8(static_cast<uint8_t>(clients_.size()));
    send_raw(from, w.data());
    if (version != kProtocolVersion) {
        LOG_WARN("Client at %s speaks protocol %u, server speaks %u", make_addr_key(from).c_str(),
                 version, kProtocolVersion);
    }
}

void Server::on_register(Reader& r, const sockaddr_in& from) {
    std::string user = r.str(64);
    std::string key = make_addr_key(from);

    if (!cfg_.open_registration) {
        send_auth_nack(from, AuthReason::BadCredentials, "Registration is closed on this server");
        return;
    }
    if (!auth_.allow_auth_attempt(key)) {
        send_auth_nack(from, AuthReason::RateLimited, "Too many attempts, wait 30 seconds");
        return;
    }
    if (!valid_username(user)) {
        send_auth_nack(from, AuthReason::BadUsername,
                       "Username must be 3-20 chars: letters, digits, _ or -");
        return;
    }

    std::string pin = auth_.register_user(user);
    if (pin.empty()) {
        send_auth_nack(from, AuthReason::UserExists, "That username is already registered");
        return;
    }

    Writer w(Type::RegisterAck);
    w.str(user);
    w.str(pin);
    send_raw(from, w.data());
}

void Server::on_login(Reader& r, const sockaddr_in& from) {
    std::string user = r.str(64);
    std::string pin = r.str(32);
    std::string key = make_addr_key(from);

    if (!auth_.allow_auth_attempt(key)) {
        send_auth_nack(from, AuthReason::RateLimited, "Too many attempts, wait 30 seconds");
        return;
    }
    if (clients_.size() >= cfg_.max_players) {
        send_auth_nack(from, AuthReason::ServerFull, "Server is full");
        return;
    }
    if (!auth_.user_exists(user)) {
        send_auth_nack(from, AuthReason::UnknownUser, "No such user, register first");
        return;
    }
    if (!auth_.check_pin(user, pin)) {
        send_auth_nack(from, AuthReason::BadCredentials, "Wrong PIN");
        return;
    }
    if (Client* existing = client_by_name(user)) {
        // A reconnect from the same machine is the common case; take over the
        // slot instead of locking the player out until the timeout expires.
        drop_client(existing->id, "reconnected");
    }

    Client c;
    c.id = next_client_id_++;
    c.session_key = random_u32();
    c.name = user;
    c.addr = from;
    c.addr_key = key;
    c.last_recv_ms = now_ms();
    clients_[c.id] = c;
    Client& stored = clients_[c.id];

    Writer w(Type::LoginAck);
    w.u32(stored.id);
    w.u32(stored.session_key);
    w.str(cfg_.map);
    w.u8(cfg_.tick_rate);
    send_to(stored, w);

    LOG_INFO("Player '%s' joined as id %u from %s", stored.name.c_str(), stored.id, key.c_str());

    Writer join(Type::PlayerJoin);
    join.u32(stored.id);
    join.str(stored.name);
    broadcast(join, &stored);

    send_world_state(stored);
    broadcast_roster();
}

// Sends the joining player everything that already exists: the roster and every
// remote vehicle with its config.
void Server::send_world_state(Client& c) {
    for (auto& kv : clients_) {
        Client& other = kv.second;
        if (other.id == c.id) continue;

        Writer join(Type::PlayerJoin);
        join.u32(other.id);
        join.str(other.name);
        send_to(c, join);

        for (auto& vkv : other.vehicles) {
            Vehicle& v = vkv.second;
            Writer sp(Type::VehicleSpawnB);
            sp.u32(other.id);
            sp.u32(v.id);
            sp.str(v.model);
            sp.str(v.config);
            sp.str(v.plate);
            sp.u32(v.color);
            send_to(c, sp);
        }
    }
}

void Server::on_pos_update(Client& c, Reader& r) {
    uint32_t veh_id = r.u32();
    uint32_t seq = r.u32();
    float tim = r.f32();
    float px = r.f32(), py = r.f32(), pz = r.f32();
    float qx = r.f32(), qy = r.f32(), qz = r.f32(), qw = r.f32();
    float vx = r.f32(), vy = r.f32(), vz = r.f32();
    float ax = r.f32(), ay = r.f32(), az = r.f32();

    if (!finite3(px, py, pz) || !finite3(vx, vy, vz) || !finite3(ax, ay, az) ||
        !finite3(qx, qy, qz) || !std::isfinite(qw) || !std::isfinite(tim)) {
        LOG_DEBUG("Dropping non-finite position from '%s'", c.name.c_str());
        return;
    }

    auto it = c.vehicles.find(veh_id);
    if (it == c.vehicles.end()) return;  // position for a vehicle we were never told about
    if (!seq_newer(seq, it->second.last_seq)) return;  // stale or duplicated datagram
    it->second.last_seq = seq;

    Writer w(Type::PosBroadcast);
    w.u32(c.id);
    w.u32(veh_id);
    w.u32(seq);
    w.f32(tim);
    w.f32(px); w.f32(py); w.f32(pz);
    w.f32(qx); w.f32(qy); w.f32(qz); w.f32(qw);
    w.f32(vx); w.f32(vy); w.f32(vz);
    w.f32(ax); w.f32(ay); w.f32(az);
    w.u16(c.ping_ms);
    broadcast(w, &c);
}

void Server::on_input_update(Client& c, Reader& r, const uint8_t*, size_t) {
    uint32_t veh_id = r.u32();
    uint8_t count = r.u8();
    if (count > 16) return;
    if (!c.vehicles.count(veh_id)) return;

    Writer w(Type::InputBroadcast);
    w.u32(c.id);
    w.u32(veh_id);
    w.u8(count);
    for (uint8_t i = 0; i < count; ++i) {
        uint8_t id = r.u8();
        float value = r.f32();
        if (!std::isfinite(value)) return;
        w.u8(id);
        w.f32(std::max(-10.0f, std::min(10.0f, value)));
    }
    broadcast(w, &c);
}

void Server::on_gear_update(Client& c, Reader& r) {
    uint32_t veh_id = r.u32();
    std::string gear = r.str(8);
    if (!c.vehicles.count(veh_id)) return;

    Writer w(Type::GearBroadcast);
    w.u32(c.id);
    w.u32(veh_id);
    w.str(gear);
    broadcast(w, &c);
}

void Server::on_vehicle_spawn(Client& c, Reader& r) {
    uint32_t veh_id = r.u32();
    std::string model = r.str(64);
    std::string config = r.str(kMaxConfigBytes);
    std::string plate = r.str(32);
    uint32_t color = r.u32();

    if (model.empty()) return;
    if (!c.vehicles.count(veh_id) && c.vehicles.size() >= kMaxVehiclesPerPlayer) {
        LOG_WARN("Player '%s' exceeded the vehicle limit", c.name.c_str());
        return;
    }

    Vehicle v;
    v.id = veh_id;
    v.model = model;
    v.config = config;
    v.plate = plate;
    v.color = color;
    auto existing = c.vehicles.find(veh_id);
    if (existing != c.vehicles.end()) v.last_seq = existing->second.last_seq;
    c.vehicles[veh_id] = v;

    LOG_INFO("Player '%s' spawned vehicle %u (%s)", c.name.c_str(), veh_id, model.c_str());

    Writer w(Type::VehicleSpawnB);
    w.u32(c.id);
    w.u32(veh_id);
    w.str(model);
    w.str(config);
    w.str(plate);
    w.u32(color);
    broadcast(w, &c);
}

void Server::on_vehicle_despawn(Client& c, Reader& r) {
    uint32_t veh_id = r.u32();
    if (!c.vehicles.erase(veh_id)) return;

    Writer w(Type::VehicleDespawnB);
    w.u32(c.id);
    w.u32(veh_id);
    broadcast(w, &c);
}

void Server::on_vehicle_reset(Client& c, Reader& r) {
    uint32_t veh_id = r.u32();
    float px = r.f32(), py = r.f32(), pz = r.f32();
    float qx = r.f32(), qy = r.f32(), qz = r.f32(), qw = r.f32();
    if (!c.vehicles.count(veh_id)) return;
    if (!finite3(px, py, pz) || !finite3(qx, qy, qz) || !std::isfinite(qw)) return;

    Writer w(Type::VehicleResetB);
    w.u32(c.id);
    w.u32(veh_id);
    w.f32(px); w.f32(py); w.f32(pz);
    w.f32(qx); w.f32(qy); w.f32(qz); w.f32(qw);
    broadcast(w, &c);
}

void Server::on_chat(Client& c, Reader& r) {
    std::string msg = r.str(kMaxChatBytes);
    if (msg.empty()) return;

    uint64_t now = now_ms();
    if (now - c.chat_window_ms > kChatWindowMs) {
        c.chat_window_ms = now;
        c.chat_tokens = 0;
    }
    if (c.chat_tokens >= kChatPerWindow) return;
    c.chat_tokens++;

    // Strip control characters so a client cannot inject newlines into the log
    // or break the in-game chat UI.
    std::string clean;
    clean.reserve(msg.size());
    for (char ch : msg) {
        if (static_cast<unsigned char>(ch) >= 0x20 || ch == '\t') clean.push_back(ch);
    }
    if (clean.empty()) return;

    LOG_INFO("[chat] %s: %s", c.name.c_str(), clean.c_str());

    Writer w(Type::ChatBroadcast);
    w.u32(c.id);
    w.str(c.name);
    w.str(clean);
    broadcast(w, nullptr);
}

void Server::on_ping(Client& c, Reader& r) {
    uint32_t ping_id = r.u32();
    float client_time = r.f32();
    uint16_t rtt = r.u16();
    if (rtt < 10000) c.ping_ms = rtt;

    Writer w(Type::Pong);
    w.u32(ping_id);
    w.f32(client_time);
    send_to(c, w);
}

void Server::broadcast_roster() {
    if (clients_.empty()) return;

    for (auto& kv : clients_) {
        Client& target = kv.second;
        Writer w(Type::Roster);
        w.u8(static_cast<uint8_t>(clients_.size()));
        for (auto& okv : clients_) {
            const Client& o = okv.second;
            w.u32(o.id);
            w.str(o.name);
            w.u16(o.ping_ms);
            w.u8(o.id == target.id ? 1 : 0);
        }
        send_to(target, w);
    }
}

void Server::drop_client(uint32_t id, const std::string& reason) {
    auto it = clients_.find(id);
    if (it == clients_.end()) return;
    Client gone = it->second;
    clients_.erase(it);

    LOG_INFO("Player '%s' (id %u) %s", gone.name.c_str(), gone.id, reason.c_str());

    for (auto& vkv : gone.vehicles) {
        Writer w(Type::VehicleDespawnB);
        w.u32(gone.id);
        w.u32(vkv.second.id);
        broadcast(w, nullptr);
    }

    Writer w(Type::PlayerLeave);
    w.u32(gone.id);
    w.str(gone.name);
    broadcast(w, nullptr);
    broadcast_roster();
}

void Server::check_timeouts() {
    uint64_t now = now_ms();
    std::vector<uint32_t> dead;
    for (auto& kv : clients_) {
        if (now - kv.second.last_recv_ms > kClientTimeoutMs) dead.push_back(kv.first);
    }
    for (uint32_t id : dead) drop_client(id, "timed out");
}

}  // namespace lanmp
