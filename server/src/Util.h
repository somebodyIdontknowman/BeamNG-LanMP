#pragma once

#include <chrono>
#include <cstdint>

namespace lanmp {

inline uint64_t now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

}  // namespace lanmp
