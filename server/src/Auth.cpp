#include "Auth.h"

#include "Logger.h"
#include "Util.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <random>
#include <sstream>

namespace lanmp {
namespace {

constexpr uint32_t kAuthAttemptsPerWindow = 5;
constexpr uint64_t kAuthWindowMs          = 30000;

// Minimal SHA-256 so the server keeps its zero-dependency build. Good enough
// for hashing LAN PINs at rest; it is not a password KDF.
struct Sha256 {
    uint32_t state[8];
    uint64_t bitlen;
    uint8_t data[64];
    uint32_t datalen;

    static const uint32_t k[64];

    Sha256() { reset(); }

    void reset() {
        datalen = 0;
        bitlen = 0;
        state[0] = 0x6a09e667; state[1] = 0xbb67ae85; state[2] = 0x3c6ef372; state[3] = 0xa54ff53a;
        state[4] = 0x510e527f; state[5] = 0x9b05688c; state[6] = 0x1f83d9ab; state[7] = 0x5be0cd19;
    }

    static uint32_t rotr(uint32_t x, uint32_t n) { return (x >> n) | (x << (32 - n)); }

    void transform() {
        uint32_t m[64];
        for (int i = 0; i < 16; ++i) {
            m[i] = (uint32_t)data[i * 4] << 24 | (uint32_t)data[i * 4 + 1] << 16 |
                   (uint32_t)data[i * 4 + 2] << 8 | (uint32_t)data[i * 4 + 3];
        }
        for (int i = 16; i < 64; ++i) {
            uint32_t s0 = rotr(m[i - 15], 7) ^ rotr(m[i - 15], 18) ^ (m[i - 15] >> 3);
            uint32_t s1 = rotr(m[i - 2], 17) ^ rotr(m[i - 2], 19) ^ (m[i - 2] >> 10);
            m[i] = m[i - 16] + s0 + m[i - 7] + s1;
        }
        uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
        uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
        for (int i = 0; i < 64; ++i) {
            uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = h + S1 + ch + k[i] + m[i];
            uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = S0 + mj;
            h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
        }
        state[0] += a; state[1] += b; state[2] += c; state[3] += d;
        state[4] += e; state[5] += f; state[6] += g; state[7] += h;
    }

    void update(const uint8_t* p, size_t len) {
        for (size_t i = 0; i < len; ++i) {
            data[datalen++] = p[i];
            if (datalen == 64) { transform(); bitlen += 512; datalen = 0; }
        }
    }

    void finalize(uint8_t out[32]) {
        uint32_t i = datalen;
        if (datalen < 56) {
            data[i++] = 0x80;
            while (i < 56) data[i++] = 0;
        } else {
            data[i++] = 0x80;
            while (i < 64) data[i++] = 0;
            transform();
            std::memset(data, 0, 56);
        }
        bitlen += (uint64_t)datalen * 8;
        for (int j = 0; j < 8; ++j) data[63 - j] = (uint8_t)(bitlen >> (j * 8));
        transform();
        for (int j = 0; j < 4; ++j) {
            for (int s = 0; s < 8; ++s) out[s * 4 + (3 - j)] = (state[s] >> (j * 8)) & 0xFF;
        }
    }
};

const uint32_t Sha256::k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

std::string to_hex(const uint8_t* data, size_t len) {
    static const char* h = "0123456789abcdef";
    std::string out(len * 2, '0');
    for (size_t i = 0; i < len; ++i) {
        out[i * 2] = h[(data[i] >> 4) & 0xF];
        out[i * 2 + 1] = h[data[i] & 0xF];
    }
    return out;
}

std::mt19937_64& rng() {
    static std::mt19937_64 gen(std::random_device{}() ^ now_ms());
    return gen;
}

}  // namespace

bool valid_username(const std::string& name) {
    if (name.size() < 3 || name.size() > 20) return false;
    for (size_t i = 0; i < name.size(); ++i) {
        char c = name[i];
        bool alnum = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        bool extra = (c == '_' || c == '-');
        if (!alnum && !(extra && i > 0)) return false;
    }
    return true;
}

std::string sha256_hex(const std::string& input) {
    Sha256 sha;
    sha.update(reinterpret_cast<const uint8_t*>(input.data()), input.size());
    uint8_t out[32];
    sha.finalize(out);
    return to_hex(out, 32);
}

Auth::Auth(std::string users_file) : users_file_(std::move(users_file)) { load(); }

std::string Auth::gen_pin() {
    std::uniform_int_distribution<int> dist(0, 999999);
    char buf[8];
    std::snprintf(buf, sizeof(buf), "%06d", dist(rng()));
    return buf;
}

std::string Auth::gen_salt() {
    std::uniform_int_distribution<int> dist(0, 255);
    uint8_t b[16];
    for (int i = 0; i < 16; ++i) b[i] = (uint8_t)dist(rng());
    return to_hex(b, 16);
}

std::string Auth::hash_pin(const std::string& pin, const std::string& salt) {
    // Iterated so a stolen users file is not trivially brute forced back to the
    // 6 digit PIN.
    std::string h = sha256_hex(salt + "|" + pin);
    for (int i = 0; i < 20000; ++i) h = sha256_hex(h + salt);
    return h;
}

std::string Auth::register_user(const std::string& username) {
    if (!valid_username(username)) return "";
    std::lock_guard<std::mutex> lk(mu_);
    if (users_.count(username)) return "";
    std::string pin = gen_pin();
    std::string salt = gen_salt();
    users_[username] = User{username, salt, hash_pin(pin, salt)};
    save_locked();
    LOG_INFO("Registered user '%s'.", username.c_str());
    return pin;
}

bool Auth::check_pin(const std::string& username, const std::string& pin) const {
    std::lock_guard<std::mutex> lk(mu_);
    auto it = users_.find(username);
    if (it == users_.end()) return false;
    const std::string expected = it->second.pin_hash;
    const std::string actual = hash_pin(pin, it->second.salt);
    if (expected.size() != actual.size()) return false;
    unsigned char diff = 0;
    for (size_t i = 0; i < expected.size(); ++i) diff |= (unsigned char)(expected[i] ^ actual[i]);
    return diff == 0;
}

bool Auth::user_exists(const std::string& username) const {
    std::lock_guard<std::mutex> lk(mu_);
    return users_.count(username) != 0;
}

size_t Auth::user_count() const {
    std::lock_guard<std::mutex> lk(mu_);
    return users_.size();
}

bool Auth::allow_auth_attempt(const std::string& addr_key) {
    std::lock_guard<std::mutex> lk(mu_);
    Bucket& b = auth_buckets_[addr_key];
    uint64_t now = now_ms();
    if (now - b.window_start_ms > kAuthWindowMs) {
        b.window_start_ms = now;
        b.count = 0;
    }
    if (b.count >= kAuthAttemptsPerWindow) return false;
    b.count++;
    return true;
}

void Auth::save_locked() const {
    std::ofstream f(users_file_, std::ios::trunc);
    if (!f) {
        LOG_WARN("Could not write users file: %s", users_file_.c_str());
        return;
    }
    for (const auto& kv : users_) {
        f << kv.second.username << '\t' << kv.second.salt << '\t' << kv.second.pin_hash << '\n';
    }
}

void Auth::load() {
    std::ifstream f(users_file_);
    if (!f) return;
    std::string line;
    while (std::getline(f, line)) {
        std::istringstream ss(line);
        User u;
        if (ss >> u.username >> u.salt >> u.pin_hash) users_[u.username] = u;
    }
    LOG_INFO("Loaded %zu registered user(s) from %s", users_.size(), users_file_.c_str());
}

}  // namespace lanmp
