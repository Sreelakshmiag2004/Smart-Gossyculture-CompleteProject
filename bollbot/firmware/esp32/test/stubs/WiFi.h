#pragma once
#include "Arduino.h"
#define WL_CONNECTED 3
#define WIFI_STA 1
class WiFiClient {};
struct WiFiStub { void mode(int){} void setAutoReconnect(bool){} void begin(const char*, const char*){} int status(){return WL_CONNECTED;} void reconnect(){} int RSSI(){return -55;} };
extern WiFiStub WiFi;
