// BollBot ESP32 firmware: pump with safety interlocks, arm servos, MQTT link to the Pi.
//
// Libraries (Arduino Library Manager or platformio.ini):
//   PubSubClient (Nick O'Leary) 2.8, ArduinoJson 7.x, Adafruit PWM Servo Driver Library
// Board: ESP32 Dev Module (Arduino-ESP32 core 2.x or 3.x)
//
// MQTT topics (prefix cart/<CART_ID>/):
//   cmd/spray       <- {"id":"s-42","ms":2700}
//   cmd/servo       <- {"id":"m-7","angles":[90,60,120,90],"speed_dps":30}  or {"id":"m-8","home":true}
//   cmd/effector    <- {"id":"e-3","on":true,"ms":4000}  or {"id":"e-4","on":false}
//   event/effector_ack -> {"id","result","reason"}
//   event/spray_ack -> {"id","result","reason"}          (accepted or why not)
//   event/spray     -> {"id","completed","ms_requested","ms_on","reason"}  (when it ends)
//   event/servo_ack -> {"id","accepted","error"}
//   event/servo_done-> {"id"}                            (target reached)
//   status          -> 1 Hz safety + servo state
//   esp/online      -> "1" / "0" (retained; "0" is the broker's last will)
//
// Arm and picking head move only while the E-stop is released, the dead-man
// button is held and the Pi link is up. Releasing the dead-man mid-move HOLDS
// the arm where it is (torque on) and stops the picking head at once.
//
// Power-up: servos stay limp until the first servo command. Hobby servos do
// not report their position, so put the arm in its HOME pose by hand before
// power-on and send {"home":true} first; otherwise it jumps to home at full speed.
//
// All safety DECISIONS are in core.cpp (unit-tested on a PC). This file only
// reads pins, moves data and writes pins.

#include <Adafruit_PWMServoDriver.h>
#include <ArduinoJson.h>
#include <PubSubClient.h>
#include <WiFi.h>
#include <Wire.h>

#include "config.h"
#include "core.h"
#include "secrets.h"   // copy secrets.example.h -> secrets.h

static WiFiClient wifi;
static PubSubClient mqtt(wifi);
static Adafruit_PWMServoDriver pwm(0x40, Wire);

static bb::SprayController spray(SPRAY_MIN_MS, SPRAY_MAX_MS, SPRAY_COOLDOWN_MS);
static bb::ServoPlanner arm(kJoints, kNumJoints);
static bb::EffectorController effector(EFFECTOR_MAX_MS);
static const bb::SafetyLimits kLimits;

static String topicPrefix;
static float usFront = -1, usSide = -1;
static uint32_t usFrontAt = 0, usSideAt = 0, lastUs = 0, lastStatus = 0, lastServo = 0,
                lastReconnect = 0;
static bool usNextFront = true;
static bool servosEnabled = false;
static char servoCmdId[33] = {0};
static bool servoAwaitDone = false;
static uint16_t lastTicks[bb::kMaxJoints];

static String topic(const char* suffix) { return topicPrefix + suffix; }

static float readUltrasonicCm(int trig, int echo) {
  digitalWrite(trig, LOW);
  delayMicroseconds(2);
  digitalWrite(trig, HIGH);
  delayMicroseconds(10);
  digitalWrite(trig, LOW);
  unsigned long us = pulseIn(echo, HIGH, US_TIMEOUT_US);
  return us == 0 ? -1.0f : us / 58.0f;   // -1 = no echo = nothing in range
}

static bb::SafetyInputs readSafety(uint32_t now) {
  bb::SafetyInputs in;
  in.estop_pressed = digitalRead(PIN_ESTOP_SENSE) == HIGH;
  in.deadman_held = digitalRead(PIN_DEADMAN) == LOW;
  in.us_front_cm = usFront;
  in.us_side_cm = usSide;
  uint32_t older = (int32_t)(usFrontAt - usSideAt) < 0 ? usFrontAt : usSideAt;
  in.us_age_ms = now - older;
  in.link_up = mqtt.connected();
  return in;
}

static void publishJson(const char* suffix, JsonDocument& doc, bool retained = false) {
  char buf[512];
  size_t n = serializeJson(doc, buf, sizeof(buf));
  mqtt.publish(topic(suffix).c_str(), (const uint8_t*)buf, n, retained);
}

static void setServoOutputs(bool enabled) {
  digitalWrite(PIN_SERVO_OE, enabled ? LOW : HIGH);
  servosEnabled = enabled;
}

static void writeServos() {
  for (int i = 0; i < arm.joints(); ++i) {
    uint16_t t = bb::pulseUsToTicks(bb::angleToPulseUs(arm.current(i), kJoints[i]));
    if (t != lastTicks[i]) {
      pwm.setPWM(kJoints[i].channel, 0, t);
      lastTicks[i] = t;
    }
  }
}

static void onSpray(JsonDocument& doc, uint32_t now) {
  const char* id = doc["id"] | "";
  uint32_t ms = doc["ms"] | 0;
  bb::Block why = bb::Block::NONE;
  bb::StartResult r = spray.start(id, ms, now, bb::sprayBlock(readSafety(now), kLimits), &why);
  JsonDocument ack;
  ack["id"] = id;
  ack["result"] = bb::startResultName(r);
  ack["reason"] = bb::blockName(why);
  publishJson("/event/spray_ack", ack);
}

static void onServo(JsonDocument& doc, uint32_t now) {
  const char* id = doc["id"] | "";
  float speed = doc["speed_dps"] | 30.0f;
  char err[64] = {0};
  bool ok;
  bb::Block gate = bb::motionBlock(readSafety(now));
  if (gate != bb::Block::NONE) {
    snprintf(err, sizeof(err), "%s", bb::blockName(gate));
    ok = false;
  } else if (doc["home"] | false) {
    arm.goHome(speed);
    ok = true;
  } else {
    JsonArray a = doc["angles"].as<JsonArray>();
    float deg[bb::kMaxJoints];
    int n = 0;
    for (JsonVariant v : a) {
      if (n >= bb::kMaxJoints) { n = bb::kMaxJoints + 1; break; }
      deg[n++] = v.as<float>();
    }
    ok = arm.setTarget(deg, n, speed, err, sizeof(err));
  }
  if (ok) {
    strncpy(servoCmdId, id, sizeof(servoCmdId) - 1);
    servoAwaitDone = true;
    setServoOutputs(true);
  }
  JsonDocument ack;
  ack["id"] = id;
  ack["accepted"] = ok;
  ack["error"] = err;
  publishJson("/event/servo_ack", ack);
}

static void onEffector(JsonDocument& doc, uint32_t now) {
  const char* id = doc["id"] | "";
  JsonDocument ack;
  ack["id"] = id;
  if (!(doc["on"] | false)) {
    effector.stop();
    ack["result"] = "ok";
    ack["reason"] = "none";
  } else {
    bb::Block why = bb::Block::NONE;
    bb::StartResult r = effector.start(doc["ms"] | 0, now, bb::motionBlock(readSafety(now)), &why);
    ack["result"] = bb::startResultName(r);
    ack["reason"] = bb::blockName(why);
  }
  publishJson("/event/effector_ack", ack);
}

static void onMessage(char* t, byte* payload, unsigned int len) {
  JsonDocument doc;
  if (deserializeJson(doc, payload, len)) return;   // malformed: ignore
  uint32_t now = millis();
  String s(t);
  if (s.endsWith("/cmd/spray")) onSpray(doc, now);
  else if (s.endsWith("/cmd/servo")) onServo(doc, now);
  else if (s.endsWith("/cmd/effector")) onEffector(doc, now);
}

static void maintainLink(uint32_t now) {
  static bool tried = false;   // first attempt immediately at boot, then every RECONNECT_MS
  if (mqtt.connected() || (tried && now - lastReconnect < RECONNECT_MS)) return;
  tried = true;
  lastReconnect = now;
  if (WiFi.status() != WL_CONNECTED) {
    WiFi.reconnect();
    return;
  }
  String cid = String(CART_ID) + "-esp32";
  if (mqtt.connect(cid.c_str(), MQTT_USER, MQTT_PASSWORD, topic("/esp/online").c_str(), 1, true, "0")) {
    mqtt.publish(topic("/esp/online").c_str(), "1", true);
    mqtt.subscribe(topic("/cmd/spray").c_str(), 1);
    mqtt.subscribe(topic("/cmd/servo").c_str(), 1);
    mqtt.subscribe(topic("/cmd/effector").c_str(), 1);
  }
}

static void publishStatus(uint32_t now, const bb::SafetyInputs& in, bb::Block gate) {
  JsonDocument d;
  d["deadman"] = in.deadman_held;
  d["estop"] = in.estop_pressed;
  d["us_front_cm"] = in.us_front_cm;
  d["us_side_cm"] = in.us_side_cm;
  d["us_age_ms"] = in.us_age_ms;
  d["block"] = bb::blockName(gate);
  d["pump"] = spray.pumpOn();
  d["spray_ms_left"] = spray.remainingMs(now);
  JsonArray s = d["servos"].to<JsonArray>();
  for (int i = 0; i < arm.joints(); ++i) s.add(arm.current(i));
  d["servo_moving"] = arm.moving();
  d["servo_outputs"] = servosEnabled;
  d["effector"] = effector.on();
  d["motion_block"] = bb::blockName(bb::motionBlock(in));
  d["rssi"] = WiFi.RSSI();
  d["uptime_s"] = now / 1000;
  publishJson("/status", d);
}

void setup() {
  pinMode(PIN_PUMP, OUTPUT);
  digitalWrite(PIN_PUMP, LOW);              // pump OFF before anything else
  pinMode(PIN_BLOWER, OUTPUT);
  digitalWrite(PIN_BLOWER, LOW);
  pinMode(PIN_ROLLERS, OUTPUT);
  digitalWrite(PIN_ROLLERS, LOW);
  pinMode(PIN_SERVO_OE, OUTPUT);
  setServoOutputs(false);                   // servos limp until the first command
  pinMode(PIN_LED, OUTPUT);
  pinMode(PIN_DEADMAN, INPUT_PULLUP);
  pinMode(PIN_ESTOP_SENSE, INPUT_PULLUP);
  pinMode(PIN_US_FRONT_TRIG, OUTPUT);
  pinMode(PIN_US_SIDE_TRIG, OUTPUT);
  pinMode(PIN_US_FRONT_ECHO, INPUT);
  pinMode(PIN_US_SIDE_ECHO, INPUT);

  Serial.begin(115200);
  Wire.begin(PIN_SDA, PIN_SCL);
  pwm.begin();
  pwm.setOscillatorFrequency(25000000);     // calibrate per board if angles are off
  pwm.setPWMFreq(50);
  for (int i = 0; i < bb::kMaxJoints; ++i) lastTicks[i] = 0xFFFF;

  topicPrefix = String("cart/") + CART_ID;
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  mqtt.setServer(MQTT_HOST, MQTT_PORT);
  mqtt.setBufferSize(768);
  mqtt.setCallback(onMessage);
}

void loop() {
  uint32_t now = millis();
  maintainLink(now);
  mqtt.loop();

  if (now - lastUs >= US_PERIOD_MS) {       // alternate sensors to avoid cross-talk
    lastUs = now;
    if (usNextFront) { usFront = readUltrasonicCm(PIN_US_FRONT_TRIG, PIN_US_FRONT_ECHO); usFrontAt = millis(); }
    else { usSide = readUltrasonicCm(PIN_US_SIDE_TRIG, PIN_US_SIDE_ECHO); usSideAt = millis(); }
    usNextFront = !usNextFront;
  }

  now = millis();
  bb::SafetyInputs in = readSafety(now);
  bb::Block gate = bb::sprayBlock(in, kLimits);

  bb::SprayEvent ev;
  bool pumpOn = spray.tick(now, gate, &ev);
  digitalWrite(PIN_PUMP, pumpOn ? HIGH : LOW);
  digitalWrite(PIN_LED, pumpOn && ((now / 100) % 2) ? HIGH : LOW);
  if (ev.valid) {
    JsonDocument d;
    d["id"] = ev.id;
    d["completed"] = ev.completed;
    d["ms_requested"] = ev.ms_requested;
    d["ms_on"] = ev.ms_on;
    d["reason"] = bb::blockName(ev.reason);
    publishJson("/event/spray", d);
  }

  if (in.estop_pressed) {                   // E-stop: freeze and cut servo outputs
    arm.hold();
    if (servosEnabled) setServoOutputs(false);
    servoAwaitDone = false;
  } else if (bb::motionBlock(in) != bb::Block::NONE) {   // dead-man released or link lost:
    arm.hold();                             // HOLD position, keep torque on.
    servoAwaitDone = false;                 // A limp hobby arm would fall under gravity.
  } else if (now - lastServo >= SERVO_PERIOD_MS) {
    uint32_t dt = now - lastServo;
    lastServo = now;
    if (servosEnabled) {
      arm.tick(dt > 100 ? 100 : dt);
      writeServos();
      if (servoAwaitDone && !arm.moving()) {
        JsonDocument d;
        d["id"] = servoCmdId;
        publishJson("/event/servo_done", d);
        servoAwaitDone = false;
      }
    }
  }

  bool effOn = effector.tick(now, bb::motionBlock(in));
  digitalWrite(PIN_BLOWER, effOn ? HIGH : LOW);
  digitalWrite(PIN_ROLLERS, effOn ? HIGH : LOW);

  if (now - lastStatus >= STATUS_PERIOD_MS) {
    lastStatus = now;
    if (mqtt.connected()) publishStatus(now, in, gate);
  }
}
