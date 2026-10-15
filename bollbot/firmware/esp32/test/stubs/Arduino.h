// Minimal host stand-in for the Arduino core (test only).
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <map>
typedef uint8_t byte;
#define HIGH 1
#define LOW 0
#define INPUT 0
#define OUTPUT 1
#define INPUT_PULLUP 2
extern uint32_t g_millis;
extern std::map<int,int> g_pin_out, g_pin_in;
inline uint32_t millis() { return g_millis; }
inline void pinMode(int, int) {}
inline void digitalWrite(int p, int v) { g_pin_out[p] = v; }
inline int digitalRead(int p) { return g_pin_in.count(p) ? g_pin_in[p] : HIGH; }
inline void delayMicroseconds(unsigned) {}
extern unsigned long g_pulse_us;
inline unsigned long pulseIn(int, int, unsigned long) { return g_pulse_us; }
struct SerialStub { void begin(long) {} } ;
extern SerialStub Serial;
class String {
 public:
  std::string s;
  String() {}
  String(const char* c) : s(c) {}
  String(const std::string& x) : s(x) {}
  const char* c_str() const { return s.c_str(); }
  bool endsWith(const char* suf) const { size_t n = strlen(suf); return s.size() >= n && s.compare(s.size()-n, n, suf) == 0; }
  String operator+(const char* o) const { return String(s + o); }
  String operator+(const String& o) const { return String(s + o.s); }
};
