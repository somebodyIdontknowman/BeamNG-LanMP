#pragma once

// LANMP wire protocol.
//
// All integers are little endian. Strings are length prefixed with a u16.
// Every client -> server packet that is not part of the handshake carries an
// auth header (player id + session key) directly after the type byte.

#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

namespace lanmp {

constexpr uint16_t kProtocolVersion = 2;
constexpr size_t   kMaxDatagram     = 60000;  // hard cap, spawn packets are the big ones
constexpr size_t   kMaxStateBytes   = 512;    // position/input packets stay well under the MTU

enum class Type : uint8_t {
    Hello           = 0x01,  // C->S  u16 version, string clientVersion
    HelloAck        = 0x02,  // S->C  u16 version, string serverName, u8 maxPlayers, u8 tickRate, string map
    Register        = 0x03,  // C->S  string user
    RegisterAck     = 0x04,  // S->C  string user, string pin
    Login           = 0x05,  // C->S  string user, string pin
    LoginAck        = 0x06,  // S->C  u32 playerId, u32 sessionKey, string map, u8 tickRate
    AuthNack        = 0x07,  // S->C  u8 reason, string message

    PosUpdate       = 0x10,  // C->S  auth, u32 vehId, u32 seq, f32 tim, pos3, rot4, vel3, rvel3
    PosBroadcast    = 0x11,  // S->C  u32 pid, u32 vehId, u32 seq, f32 tim, pos3, rot4, vel3, rvel3, u16 senderPing
    InputUpdate     = 0x12,  // C->S  auth, u32 vehId, u8 count, {u8 id, f32 value}
    InputBroadcast  = 0x13,  // S->C  u32 pid, u32 vehId, u8 count, {u8 id, f32 value}
    GearUpdate      = 0x14,  // C->S  auth, u32 vehId, string gear
    GearBroadcast   = 0x15,  // S->C  u32 pid, u32 vehId, string gear

    VehicleSpawn    = 0x20,  // C->S  auth, u32 vehId, string model, string configJson, string plate, u32 color
    VehicleSpawnB   = 0x21,  // S->C  u32 pid, u32 vehId, string model, string configJson, string plate, u32 color
    VehicleDespawn  = 0x22,  // C->S  auth, u32 vehId
    VehicleDespawnB = 0x23,  // S->C  u32 pid, u32 vehId
    VehicleReset    = 0x24,  // C->S  auth, u32 vehId, pos3, rot4
    VehicleResetB   = 0x25,  // S->C  u32 pid, u32 vehId, pos3, rot4

    Chat            = 0x30,  // C->S  auth, string message
    ChatBroadcast   = 0x31,  // S->C  u32 pid, string name, string message

    Disconnect      = 0x40,  // C->S  auth              | S->C string reason
    Kick            = 0x41,  // S->C  string reason

    Ping            = 0x50,  // C->S  auth, u32 pingId, f32 clientTime, u16 measuredRttMs
    Pong            = 0x51,  // S->C  u32 pingId, f32 clientTime

    PlayerJoin      = 0x60,  // S->C  u32 pid, string name
    PlayerLeave     = 0x61,  // S->C  u32 pid, string name
    Roster          = 0x62,  // S->C  u8 count, {u32 pid, string name, u16 pingMs, u8 isYou}
};

enum class AuthReason : uint8_t {
    BadCredentials  = 1,
    UnknownUser     = 2,
    UserExists      = 3,
    RateLimited     = 4,
    ServerFull      = 5,
    BadVersion      = 6,
    BadUsername     = 7,
    AlreadyOnline   = 8,
};

// Input ids used by InputUpdate. Kept numeric so the hot packet stays small.
enum class InputId : uint8_t {
    Steering     = 1,
    Throttle     = 2,
    Brake        = 3,
    Parkingbrake = 4,
    Clutch       = 5,
    Lightbar     = 6,
    Headlights   = 7,
    Signal       = 8,
    Horn         = 9,
};

class Writer {
public:
    explicit Writer(Type t) { buf_.push_back(static_cast<uint8_t>(t)); }

    void u8(uint8_t v) { buf_.push_back(v); }
    void u16(uint16_t v) { raw(&v, sizeof(v)); }
    void u32(uint32_t v) { raw(&v, sizeof(v)); }
    void f32(float v) { raw(&v, sizeof(v)); }

    void str(const std::string& s) {
        uint16_t n = static_cast<uint16_t>(s.size() > 0xFFFF ? 0xFFFF : s.size());
        u16(n);
        buf_.insert(buf_.end(), s.begin(), s.begin() + n);
    }

    // Copies a run of bytes that was already validated by a Reader.
    void bytes(const uint8_t* p, size_t n) { buf_.insert(buf_.end(), p, p + n); }

    const std::vector<uint8_t>& data() const { return buf_; }
    size_t size() const { return buf_.size(); }

private:
    template <typename T>
    void raw(const T* v, size_t n) {
        const uint8_t* p = reinterpret_cast<const uint8_t*>(v);
        buf_.insert(buf_.end(), p, p + n);
    }

    std::vector<uint8_t> buf_;
};

// Bounds checked reader. Every accessor throws on truncation so a malformed
// datagram can never walk off the end of the buffer.
class Reader {
public:
    Reader(const uint8_t* data, size_t len) : data_(data), len_(len) {}

    Type type() {
        return static_cast<Type>(u8());
    }

    uint8_t u8() {
        need(1);
        return data_[pos_++];
    }

    uint16_t u16() {
        need(2);
        uint16_t v;
        std::memcpy(&v, data_ + pos_, 2);
        pos_ += 2;
        return v;
    }

    uint32_t u32() {
        need(4);
        uint32_t v;
        std::memcpy(&v, data_ + pos_, 4);
        pos_ += 4;
        return v;
    }

    float f32() {
        need(4);
        float v;
        std::memcpy(&v, data_ + pos_, 4);
        pos_ += 4;
        return v;
    }

    std::string str(size_t max_len = 4096) {
        uint16_t n = u16();
        if (n > max_len) throw std::runtime_error("string too long");
        need(n);
        std::string s(reinterpret_cast<const char*>(data_ + pos_), n);
        pos_ += n;
        return s;
    }

    size_t remaining() const { return len_ - pos_; }
    size_t offset() const { return pos_; }
    const uint8_t* at(size_t off) const { return data_ + off; }

private:
    void need(size_t n) const {
        if (pos_ + n > len_) throw std::runtime_error("packet truncated");
    }

    const uint8_t* data_;
    size_t len_;
    size_t pos_ = 0;
};

}  // namespace lanmp
