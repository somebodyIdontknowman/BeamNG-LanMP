#include "Logger.h"

#include <cstdarg>
#include <cstdio>
#include <ctime>
#include <mutex>

namespace mplog {

static Level g_level = Level::Info;
static std::mutex g_mu;

void set_level(Level lvl) { g_level = lvl; }
Level level() { return g_level; }

static void emit(Level lvl, const char* tag, const char* fmt, va_list ap) {
    if (static_cast<int>(lvl) < static_cast<int>(g_level)) return;
    std::lock_guard<std::mutex> lk(g_mu);
    std::time_t t = std::time(nullptr);
    std::tm tm{};
#ifdef _WIN32
    localtime_s(&tm, &t);
#else
    localtime_r(&t, &tm);
#endif
    char ts[24];
    std::strftime(ts, sizeof(ts), "%H:%M:%S", &tm);
    std::printf("[%s] [%s] ", ts, tag);
    std::vprintf(fmt, ap);
    std::printf("\n");
    std::fflush(stdout);
}

void raw(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    std::vprintf(fmt, ap);
    va_end(ap);
    std::fflush(stdout);
}

void info(const char* fmt, ...)  { va_list ap; va_start(ap, fmt); emit(Level::Info,  "INFO ", fmt, ap); va_end(ap); }
void warn(const char* fmt, ...)  { va_list ap; va_start(ap, fmt); emit(Level::Warn,  "WARN ", fmt, ap); va_end(ap); }
void error(const char* fmt, ...) { va_list ap; va_start(ap, fmt); emit(Level::Error, "ERROR", fmt, ap); va_end(ap); }
void debug(const char* fmt, ...) { va_list ap; va_start(ap, fmt); emit(Level::Debug, "DEBUG", fmt, ap); va_end(ap); }

} // namespace mplog
