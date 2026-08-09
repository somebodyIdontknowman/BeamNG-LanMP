#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <ctime>

namespace mplog {

enum class Level : int { Debug = 0, Info, Warn, Error };

void set_level(Level lvl);
Level level();

void raw(const char* fmt, ...);

void info(const char* fmt, ...);
void warn(const char* fmt, ...);
void error(const char* fmt, ...);
void debug(const char* fmt, ...);

} // namespace mplog

#define LOG_INFO(...)  ::mplog::info(__VA_ARGS__)
#define LOG_WARN(...)  ::mplog::warn(__VA_ARGS__)
#define LOG_ERROR(...) ::mplog::error(__VA_ARGS__)
#define LOG_DEBUG(...) ::mplog::debug(__VA_ARGS__)
