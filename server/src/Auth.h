#pragma once

#include <cstdint>
#include <map>
#include <mutex>
#include <string>

namespace lanmp {

// Username policy: 3-20 chars, [A-Za-z0-9_-], must start with a letter/digit.
bool valid_username(const std::string& name);

std::string sha256_hex(const std::string& input);

class Auth {
public:
    explicit Auth(std::string users_file);

    // Creates a user and returns its freshly generated PIN, or "" if the name
    // is invalid or already taken.
    std::string register_user(const std::string& username);

    bool check_pin(const std::string& username, const std::string& pin) const;
    bool user_exists(const std::string& username) const;
    size_t user_count() const;

    // Per-address login/register throttle. Returns false when the caller has
    // spent its budget; the window is sliding-ish (reset once it elapses).
    bool allow_auth_attempt(const std::string& addr_key);

private:
    struct User {
        std::string username;
        std::string salt;
        std::string pin_hash;
    };

    struct Bucket {
        uint32_t count = 0;
        uint64_t window_start_ms = 0;
    };

    void save_locked() const;
    void load();

    static std::string gen_pin();
    static std::string gen_salt();
    static std::string hash_pin(const std::string& pin, const std::string& salt);

    mutable std::mutex mu_;
    std::string users_file_;
    std::map<std::string, User> users_;
    std::map<std::string, Bucket> auth_buckets_;
};

}  // namespace lanmp
