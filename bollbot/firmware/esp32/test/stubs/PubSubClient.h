#pragma once
#include <functional>
#include <string>
#include <vector>
#include "Arduino.h"
#include "WiFi.h"
struct Msg { std::string topic, payload; bool retained; };
extern std::vector<Msg> g_published;
extern bool g_connected;
class PubSubClient {
 public:
  typedef void (*CB)(char*, uint8_t*, unsigned int);
  CB cb = nullptr;
  explicit PubSubClient(WiFiClient&) {}
  void setServer(const char*, int) {}
  bool setBufferSize(uint16_t) { return true; }
  void setCallback(CB c) { cb = c; }
  bool connect(const char*, const char*, const char*, const char*, int, bool, const char*) { g_connected = true; return true; }
  bool connected() { return g_connected; }
  bool publish(const char* t, const uint8_t* p, unsigned int n, bool r) { g_published.push_back({t, std::string((const char*)p, n), r}); return true; }
  bool publish(const char* t, const char* p, bool r) { g_published.push_back({t, p, r}); return true; }
  bool subscribe(const char*, int) { return true; }
  bool loop() { return true; }
};
