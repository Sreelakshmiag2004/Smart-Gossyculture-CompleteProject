// BollBot ESP32 firmware - hardware-independent core (spec Sections 5, 9, 10).
//
// Everything that decides WHETHER the pump may run or WHERE a servo may move
// lives here, with no Arduino headers, so it is unit-tested on a PC with g++
// (firmware/esp32/test/test_core.cpp). bollbot_fw.ino only reads pins and
// calls these functions.
#pragma once
#include <cstddef>
#include <cstdint>

namespace bb {

// ------------------------------------------------------------------ safety
// Why spraying is not allowed right now. NONE = allowed.
enum class Block : uint8_t {
  NONE = 0,
  ESTOP,          // emergency stop pressed
  DEADMAN,        // operator is not holding the dead-man button
  PERSON_FRONT,   // something within person_cm in front
  PERSON_SIDE,    // something within person_cm at the side
  SENSOR_STALE,   // ultrasonic readings too old (sensor task stuck)
  LINK_DOWN,      // MQTT link to the Pi lost
};
const char* blockName(Block b);

struct SafetyInputs {
  bool estop_pressed;
  bool deadman_held;
  float us_front_cm;   // < 0 means "no echo" = nothing within sensor range (~4 m)
  float us_side_cm;
  uint32_t us_age_ms;  // age of the OLDER of the two readings
  bool link_up;
};

struct SafetyLimits {
  float person_cm = 200.0f;     // spec: nobody within 2 m
  uint32_t max_age_ms = 500;
};

// Order matters: the first failing check is reported (E-stop first).
Block sprayBlock(const SafetyInputs& in, const SafetyLimits& lim);

// Arm and end-effector motion need fewer conditions than spraying: no person
// guard (the operator stands next to the arm) but the E-stop, the dead-man
// button and the Pi link must all be OK.
Block motionBlock(const SafetyInputs& in);

// ------------------------------------------------------------------- spray
enum class StartResult : uint8_t { OK = 0, BLOCKED, BUSY, BAD_DURATION, BAD_ID };
const char* startResultName(StartResult r);

struct SprayEvent {
  bool valid = false;        // true when a spray just finished or was aborted
  char id[33] = {0};
  bool completed = false;    // false = aborted by a safety block
  uint32_t ms_requested = 0;
  uint32_t ms_on = 0;        // how long the pump actually ran
  Block reason = Block::NONE;
};

// One spray at a time. The pump runs only while the safety gate stays open;
// the moment it closes, the pump stops and the spray is reported as aborted.
class SprayController {
 public:
  SprayController(uint32_t min_ms = 100, uint32_t max_ms = 5000, uint32_t cooldown_ms = 500)
      : min_ms_(min_ms), max_ms_(max_ms), cooldown_ms_(cooldown_ms) {}

  StartResult start(const char* id, uint32_t ms, uint32_t now, Block gate, Block* why = nullptr);
  // Call every loop. Returns whether the pump must be ON. Fills *ev when a spray ends.
  bool tick(uint32_t now, Block gate, SprayEvent* ev);
  bool pumpOn() const { return state_ == State::SPRAYING; }
  uint32_t remainingMs(uint32_t now) const;

 private:
  enum class State : uint8_t { IDLE, SPRAYING, COOLDOWN };
  void finish_(uint32_t now, bool completed, Block reason, SprayEvent* ev);
  uint32_t min_ms_, max_ms_, cooldown_ms_;
  State state_ = State::IDLE;
  char id_[33] = {0};
  uint32_t started_ = 0, duration_ = 0, cooldown_until_ = 0;
};

// --------------------------------------------------------------- effector
// Vacuum blower + roller motors of the picking head. Always time-limited, so
// a crashed Pi cannot leave them running; stops at once when motion is blocked.
class EffectorController {
 public:
  explicit EffectorController(uint32_t max_ms = 10000) : max_ms_(max_ms) {}
  StartResult start(uint32_t ms, uint32_t now, Block gate, Block* why = nullptr);
  void stop() { on_ = false; }
  bool tick(uint32_t now, Block gate);   // returns whether outputs must be ON
  bool on() const { return on_; }
  uint32_t remainingMs(uint32_t now) const;

 private:
  uint32_t max_ms_;
  bool on_ = false;
  uint32_t started_ = 0, duration_ = 0;
};

// ------------------------------------------------------------------ servos
constexpr int kMaxJoints = 6;

struct JointLimit {
  float min_deg;
  float max_deg;
  float home_deg;
  uint8_t channel;       // PCA9685 output 0..15
  uint16_t min_us = 500; // pulse at 0 deg  (check the servo datasheet)
  uint16_t max_us = 2500;// pulse at 180 deg
};

// Moves joints smoothly toward targets at a limited speed. Targets outside a
// joint's limits are REJECTED (never clamped), so a bad IK result cannot
// drive the arm into the frame or the plant.
class ServoPlanner {
 public:
  ServoPlanner(const JointLimit* limits, int n);
  // Returns false and writes a reason into err (size >= 64) if rejected.
  bool setTarget(const float* deg, int n, float speed_dps, char* err, size_t err_len);
  void tick(uint32_t dt_ms);
  void hold();            // stop where it is (E-stop)
  void goHome(float speed_dps);
  bool moving() const;
  int joints() const { return n_; }
  float current(int i) const { return cur_[i]; }
  float target(int i) const { return tgt_[i]; }

 private:
  const JointLimit* lim_;
  int n_;
  float cur_[kMaxJoints];
  float tgt_[kMaxJoints];
  float speed_dps_ = 30.0f;
};

constexpr float kMaxSpeedDps = 120.0f;   // hobby servos: keep motion gentle

// Servo pulse width (microseconds) for an angle, and PCA9685 ticks at 50 Hz.
uint16_t angleToPulseUs(float deg, const JointLimit& j);
uint16_t pulseUsToTicks(uint16_t us, float pwm_hz = 50.0f);

}  // namespace bb
