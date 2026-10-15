// Runs the REAL sketch (bollbot_fw.ino) on a PC against stand-in libraries
// (test/stubs/) and the real ArduinoJson header: setup(), then loop() with a
// simulated clock, MQTT commands and switch presses. See run_tests.sh.
#include <string>
#include <vector>

#include "Arduino.h"
#include "Adafruit_PWMServoDriver.h"
#include "PubSubClient.h"
#include "WiFi.h"
#include "Wire.h"

uint32_t g_millis = 0;
std::map<int, int> g_pin_out, g_pin_in, g_pwm;
unsigned long g_pulse_us = 0;       // 0 = no echo
SerialStub Serial;
WiFiStub WiFi;
TwoWire Wire;
std::vector<Msg> g_published;
bool g_connected = false;

#include "../bollbot_fw/bollbot_fw.ino"   // the sketch under test

static int g_fail = 0, g_pass = 0;
#define CHECK(c) do { if (c) ++g_pass; else { ++g_fail; std::printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

static void run(uint32_t ms) {
  for (uint32_t t = 0; t < ms; t += 5) { g_millis += 5; loop(); }
}
static void send(const char* t, const char* json) {
  std::string topicStr = std::string("cart/cart01") + t;
  onMessage((char*)topicStr.c_str(), (byte*)json, strlen(json));
}
static const Msg* last(const char* suffix) {
  std::string want = std::string("cart/cart01") + suffix;
  for (auto it = g_published.rbegin(); it != g_published.rend(); ++it)
    if (it->topic == want) return &*it;
  return nullptr;
}
static bool has(const Msg* m, const char* text) { return m && m->payload.find(text) != std::string::npos; }

int main() {
  g_pin_in[PIN_ESTOP_SENSE] = LOW;   // E-stop released
  g_pin_in[PIN_DEADMAN] = LOW;       // dead-man held
  setup();
  CHECK(g_pin_out[PIN_PUMP] == LOW);
  CHECK(g_pin_out[PIN_SERVO_OE] == HIGH);              // servos limp at boot

  run(300);                                             // connect + both ultrasonic readings
  CHECK(g_connected);
  const Msg* online = last("/esp/online");
  CHECK(online && online->payload == "1" && online->retained);

  // --- spray runs for the requested time, then reports completion
  send("/cmd/spray", "{\"id\":\"s1\",\"ms\":1000}");
  CHECK(has(last("/event/spray_ack"), "\"result\":\"ok\""));
  run(20);
  CHECK(g_pin_out[PIN_PUMP] == HIGH);
  run(1000);
  CHECK(g_pin_out[PIN_PUMP] == LOW);
  CHECK(has(last("/event/spray"), "\"completed\":true"));

  // --- releasing the dead-man stops the pump at once
  run(600);                                             // past cooldown
  send("/cmd/spray", "{\"id\":\"s2\",\"ms\":3000}");
  run(500);
  CHECK(g_pin_out[PIN_PUMP] == HIGH);
  g_pin_in[PIN_DEADMAN] = HIGH;
  run(5);
  CHECK(g_pin_out[PIN_PUMP] == LOW);
  const Msg* ev = last("/event/spray");
  CHECK(has(ev, "\"id\":\"s2\"") && has(ev, "\"completed\":false") && has(ev, "deadman_released"));
  g_pin_in[PIN_DEADMAN] = LOW;

  // --- a person within 2 m blocks a new spray
  run(600);
  g_pulse_us = 100 * 58;                                // 100 cm echo
  run(200);
  send("/cmd/spray", "{\"id\":\"s3\",\"ms\":1000}");
  CHECK(has(last("/event/spray_ack"), "\"result\":\"blocked\"") &&
        has(last("/event/spray_ack"), "person_"));
  g_pulse_us = 0;
  run(200);

  // --- bad commands are refused, malformed JSON ignored
  send("/cmd/spray", "{\"id\":\"s4\",\"ms\":9000}");
  CHECK(has(last("/event/spray_ack"), "bad_duration"));
  size_t before = g_published.size();
  send("/cmd/spray", "{not json");
  CHECK(g_published.size() == before);

  // --- servo move: accepted, outputs on, PWM written, done reported
  send("/cmd/servo", "{\"id\":\"m1\",\"angles\":[100,80,90,90],\"speed_dps\":60}");
  CHECK(has(last("/event/servo_ack"), "\"accepted\":true"));
  run(100);
  CHECK(g_pin_out[PIN_SERVO_OE] == LOW);
  CHECK(g_pwm.count(0) == 1);
  run(1000);
  CHECK(has(last("/event/servo_done"), "\"id\":\"m1\""));

  // --- out-of-limit target rejected (joint 1 minimum is 20)
  send("/cmd/servo", "{\"id\":\"m2\",\"angles\":[90,5,90,90]}");
  CHECK(has(last("/event/servo_ack"), "\"accepted\":false") && has(last("/event/servo_ack"), "joint 1"));
  send("/cmd/servo", "{\"id\":\"m3\",\"angles\":[90,90,90,90,90,90,90]}");
  CHECK(has(last("/event/servo_ack"), "\"accepted\":false"));

  // --- picking head: runs for the requested time, then switches itself off
  send("/cmd/effector", "{\"id\":\"e1\",\"on\":true,\"ms\":500}");
  CHECK(has(last("/event/effector_ack"), "\"result\":\"ok\""));
  run(20);
  CHECK(g_pin_out[PIN_BLOWER] == HIGH && g_pin_out[PIN_ROLLERS] == HIGH);
  run(600);
  CHECK(g_pin_out[PIN_BLOWER] == LOW && g_pin_out[PIN_ROLLERS] == LOW);
  send("/cmd/effector", "{\"id\":\"e2\",\"on\":true,\"ms\":60000}");
  CHECK(has(last("/event/effector_ack"), "bad_duration"));
  send("/cmd/effector", "{\"id\":\"e3\",\"on\":true,\"ms\":5000}");
  run(20);
  send("/cmd/effector", "{\"id\":\"e4\",\"on\":false}");
  run(10);
  CHECK(g_pin_out[PIN_BLOWER] == LOW);

  // --- dead-man released mid-move: arm HOLDS (torque on), head stops, move not 'done'
  send("/cmd/servo", "{\"id\":\"m6\",\"angles\":[150,80,90,90],\"speed_dps\":30}");
  send("/cmd/effector", "{\"id\":\"e5\",\"on\":true,\"ms\":5000}");
  run(300);
  g_pin_in[PIN_DEADMAN] = HIGH;
  run(10);
  float held = arm.current(0);
  CHECK(g_pin_out[PIN_BLOWER] == LOW);
  run(1000);
  CHECK(arm.current(0) == held && held < 150);
  CHECK(g_pin_out[PIN_SERVO_OE] == LOW);                 // still powered: no drop
  CHECK(!has(last("/event/servo_done"), "m6"));
  send("/cmd/servo", "{\"id\":\"m7\",\"home\":true}");
  CHECK(has(last("/event/servo_ack"), "deadman_released"));
  send("/cmd/effector", "{\"id\":\"e6\",\"on\":true,\"ms\":1000}");
  CHECK(has(last("/event/effector_ack"), "\"result\":\"blocked\""));
  g_pin_in[PIN_DEADMAN] = LOW;
  run(100);

  // --- link loss: arm HOLDS with torque (does not go limp)
  send("/cmd/servo", "{\"id\":\"m4\",\"home\":true,\"speed_dps\":10}");
  run(200);
  g_connected = false;
  g_millis += 5; loop();
  CHECK(g_pin_out[PIN_SERVO_OE] == LOW);
  run(1500);                                            // stub reconnects after 2 s
  CHECK(g_connected);

  // --- E-stop: servo outputs off, spray blocked
  g_pin_in[PIN_ESTOP_SENSE] = HIGH;
  run(20);
  CHECK(g_pin_out[PIN_SERVO_OE] == HIGH);
  send("/cmd/spray", "{\"id\":\"s5\",\"ms\":1000}");
  CHECK(has(last("/event/spray_ack"), "\"reason\":\"estop\""));
  send("/cmd/servo", "{\"id\":\"m5\",\"home\":true}");
  CHECK(has(last("/event/servo_ack"), "estop"));
  run(1000);
  CHECK(has(last("/status"), "\"block\":\"estop\""));

  std::printf("sketch: %d passed, %d failed\n", g_pass, g_fail);
  return g_fail ? 1 : 0;
}
