#pragma once

#include "Auth.h"
#include "Protocol.h"

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
using socket_t = SOCKET;
#define LANMP_INVALID_SOCK INVALID_SOCKET
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
using socket_t = int;
#define LANMP_INVALID_SOCK (-1)
#endif

namespace lanmp {

struct Vehicle {
    uint32_t id = 0;
    std::string model;
    std::string config;
    std::string plate;
    uint32_t color = 0;
    uint32_t last_seq = 0;
};

struct Client {
    uint32_t id = 0;
    uint32_t session_key = 0;
    std::string name;
    sockaddr_in addr{};
    std::string addr_key;
    uint64_t last_recv_ms = 0;
    uint16_t ping_ms = 0;

    uint32_t chat_tokens = 0;
    uint64_t chat_window_ms = 0;

    std::map<uint32_t, Vehicle> vehicles;
};

struct ServerConfig {
    uint16_t port = 4144;
    std::string users_file = "users.txt";
    std::string server_name = "LANMP Server";
    std::string map = "/levels/gridmap_v2/info.json";
    uint8_t max_players = 8;
    uint8_t tick_rate = 30;
    bool open_registration = true;
};

class Server {
public:
    explicit Server(ServerConfig cfg);
    ~Server();

    bool init();
    int run();  // blocks

    // Runs a single receive/tick iteration. Exposed for tests.
    void poll(int timeout_ms);

private:
    void close_socket();
    static std::string make_addr_key(const sockaddr_in& a);

    void send_raw(const sockaddr_in& to, const std::vector<uint8_t>& pkt);
    void send_to(const Client& c, const Writer& w);
    void broadcast(const Writer& w, const Client* except);
    void send_auth_nack(const sockaddr_in& to, AuthReason reason, const std::string& msg);

    Client* client_by_id(uint32_t id);
    Client* authenticate(Reader& r, const sockaddr_in& from);
    Client* client_by_name(const std::string& name);

    void handle_datagram(const uint8_t* data, size_t len, const sockaddr_in& from);
    void on_hello(Reader& r, const sockaddr_in& from);
    void on_register(Reader& r, const sockaddr_in& from);
    void on_login(Reader& r, const sockaddr_in& from);
    void on_pos_update(Client& c, Reader& r);
    void on_input_update(Client& c, Reader& r, const uint8_t* data, size_t len);
    void on_gear_update(Client& c, Reader& r);
    void on_vehicle_spawn(Client& c, Reader& r);
    void on_vehicle_despawn(Client& c, Reader& r);
    void on_vehicle_reset(Client& c, Reader& r);
    void on_chat(Client& c, Reader& r);
    void on_ping(Client& c, Reader& r);

    void send_world_state(Client& c);
    void broadcast_roster();
    void drop_client(uint32_t id, const std::string& reason);
    void check_timeouts();

    ServerConfig cfg_;
    Auth auth_;
    socket_t sock_ = LANMP_INVALID_SOCK;
    std::map<uint32_t, Client> clients_;
    uint32_t next_client_id_ = 1;
    uint64_t last_timeout_check_ms_ = 0;
    uint64_t last_roster_ms_ = 0;
};

}  // namespace lanmp
