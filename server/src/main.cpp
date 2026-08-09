#include "Logger.h"
#include "Server.h"

#include <cstdio>
#include <cstdlib>
#include <string>

static void usage(const char* exe) {
    std::printf(
        "lanmp_server -- LAN/online multiplayer server for the LANMP BeamNG.drive mod\n"
        "\n"
        "Usage: %s [options]\n"
        "Options:\n"
        "  --port <n>        UDP port to listen on (default 4144)\n"
        "  --users <file>    Account file for PIN auth (default users.txt)\n"
        "  --name <text>     Server name shown in the mod (default \"LANMP Server\")\n"
        "  --map <path>      Level all players must load (default gridmap_v2)\n"
        "  --max-players <n> Player cap, 1-32 (default 8)\n"
        "  --tick <n>        Position updates per second clients should send (default 30)\n"
        "  --closed          Refuse new registrations\n"
        "  --verbose         Enable debug logging\n"
        "  --help            Show this help\n"
        "\n"
        "Players register once from the in-game app; the server generates a\n"
        "6-digit PIN they use to log in afterwards.\n",
        exe);
}

int main(int argc, char** argv) {
    lanmp::ServerConfig cfg;
    bool verbose = false;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&](const char* err) -> std::string {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "missing value for %s\n", err);
                std::exit(1);
            }
            return argv[++i];
        };
        if (a == "--help" || a == "-h") { usage(argv[0]); return 0; }
        else if (a == "--port") cfg.port = static_cast<uint16_t>(std::atoi(next("--port").c_str()));
        else if (a == "--users") cfg.users_file = next("--users");
        else if (a == "--name") cfg.server_name = next("--name");
        else if (a == "--map") cfg.map = next("--map");
        else if (a == "--max-players") {
            int n = std::atoi(next("--max-players").c_str());
            if (n < 1) n = 1;
            if (n > 32) n = 32;
            cfg.max_players = static_cast<uint8_t>(n);
        } else if (a == "--tick") {
            int n = std::atoi(next("--tick").c_str());
            if (n < 5) n = 5;
            if (n > 60) n = 60;
            cfg.tick_rate = static_cast<uint8_t>(n);
        } else if (a == "--closed") cfg.open_registration = false;
        else if (a == "--verbose") verbose = true;
        else {
            std::fprintf(stderr, "unknown arg: %s\n", a.c_str());
            usage(argv[0]);
            return 1;
        }
    }

    mplog::set_level(verbose ? mplog::Level::Debug : mplog::Level::Info);

    lanmp::Server server(std::move(cfg));
    return server.run();
}
