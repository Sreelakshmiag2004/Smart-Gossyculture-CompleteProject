#include "core.h"

#include <cmath>
#include <cstdio>
#include <cstring>

namespace bb {

const char* blockName(Block b) {
  switch (b) {
    case Block::NONE: return "none";
    case Block::ESTOP: return "estop";
    case Block::DEADMAN: return "deadman_released";
    case Block::PERSON_FRONT: return "person_front";
    case Block::PERSON_SIDE: return "person_side";
    case Block::SENSOR_STALE: return "sensor_stale";
    case Block::LINK_DOWN: return "link_down";
  }
  return "unknown";
}

const char* startResultName(StartResult r) {
  switch (r) {
    case StartResult::OK: return "ok";
    case StartResult::BLOCKED: return "blocked";
    case StartResult::BUSY: return "busy";
    case StartResult::BAD_DURATION: return "bad_duration";
    case StartResult::BAD_ID: return "bad_id";
  }
  return "unknown";
}

static bool tooClose(float cm, float limit) {
  // No echo (< 0) means nothing within range: clear. NaN is treated as too close.
  if (std::isnan(cm)) return true;
  return cm >= 0.0f && cm < limit;
}

Block sprayBlock(const SafetyInputs& in, const SafetyLimits& lim) {
  if (in.estop_pressed) return Block::ESTOP;
  if (!in.deadman_held) return Block::DEADMAN;
  if (!in.link_up) return Block::LINK_DOWN;
  if (in.us_age_ms > lim.max_age_ms) return Block::SENSOR_STALE;
  if (tooClose(in.us_front_cm, lim.person_cm)) return Block::PERSON_FRONT;
  if (tooClose(in.us_side_cm, lim.person_cm)) return Block::PERSON_SIDE;
  return Block::NONE;
}

Block motionBlock(const SafetyInputs& in) {
  if (in.estop_pressed) return Block::ESTOP;
  if (!in.deadman_held) return Block::DEADMAN;
  if (!in.link_up) return Block::LINK_DOWN;
  return Block::NONE;
}

// ------------------------------------------------------------------- spray
StartResult SprayController::start(const char* id, uint32_t ms, uint32_t now, Block gate,
                                   Block* why) {
  if (why) *why = Block::NONE;
  if (id == nullptr || id[0] == '\0' || std::strlen(id) >= sizeof(id_)) return StartResult::BAD_ID;
  if (ms < min_ms_ || ms > max_ms_) return StartResult::BAD_DURATION;
  if (state_ == State::SPRAYING) return StartResult::BUSY;
  if (state_ == State::COOLDOWN && (int32_t)(now - cooldown_until_) < 0) return StartResult::BUSY;
  if (gate != Block::NONE) {
    if (why) *why = gate;
    return StartResult::BLOCKED;
  }
  std::strncpy(id_, id, sizeof(id_) - 1);
  id_[sizeof(id_) - 1] = '\0';
  started_ = now;
  duration_ = ms;
  state_ = State::SPRAYING;
  return StartResult::OK;
}

void SprayController::finish_(uint32_t now, bool completed, Block reason, SprayEvent* ev) {
  if (ev) {
    ev->valid = true;
    std::strncpy(ev->id, id_, sizeof(ev->id) - 1);
    ev->id[sizeof(ev->id) - 1] = '\0';
    ev->completed = completed;
    ev->ms_requested = duration_;
    uint32_t ran = now - started_;
    ev->ms_on = ran > duration_ ? duration_ : ran;
    ev->reason = reason;
  }
  state_ = State::COOLDOWN;
  cooldown_until_ = now + cooldown_ms_;
}

bool SprayController::tick(uint32_t now, Block gate, SprayEvent* ev) {
  if (ev) ev->valid = false;
  if (state_ == State::SPRAYING) {
    if (gate != Block::NONE) {
      finish_(now, false, gate, ev);          // stop at once
    } else if (now - started_ >= duration_) { // unsigned maths: safe across millis() wrap
      finish_(now, true, Block::NONE, ev);
    }
  } else if (state_ == State::COOLDOWN && (int32_t)(now - cooldown_until_) >= 0) {
    state_ = State::IDLE;
  }
  return state_ == State::SPRAYING;
}

uint32_t SprayController::remainingMs(uint32_t now) const {
  if (state_ != State::SPRAYING) return 0;
  uint32_t ran = now - started_;
  return ran >= duration_ ? 0 : duration_ - ran;
}

// --------------------------------------------------------------- effector
StartResult EffectorController::start(uint32_t ms, uint32_t now, Block gate, Block* why) {
  if (why) *why = Block::NONE;
  if (ms == 0 || ms > max_ms_) return StartResult::BAD_DURATION;
  if (gate != Block::NONE) {
    if (why) *why = gate;
    return StartResult::BLOCKED;
  }
  on_ = true;            // a new start while on simply restarts the timer
  started_ = now;
  duration_ = ms;
  return StartResult::OK;
}

bool EffectorController::tick(uint32_t now, Block gate) {
  if (on_ && (gate != Block::NONE || now - started_ >= duration_)) on_ = false;
  return on_;
}

uint32_t EffectorController::remainingMs(uint32_t now) const {
  if (!on_) return 0;
  uint32_t ran = now - started_;
  return ran >= duration_ ? 0 : duration_ - ran;
}

// ------------------------------------------------------------------ servos
ServoPlanner::ServoPlanner(const JointLimit* limits, int n) : lim_(limits) {
  n_ = n < 0 ? 0 : (n > kMaxJoints ? kMaxJoints : n);
  for (int i = 0; i < n_; ++i) cur_[i] = tgt_[i] = lim_[i].home_deg;
}

bool ServoPlanner::setTarget(const float* deg, int n, float speed_dps, char* err, size_t err_len) {
  if (n != n_) {
    std::snprintf(err, err_len, "expected %d angles, got %d", n_, n);
    return false;
  }
  if (!(speed_dps > 0.0f) || speed_dps > kMaxSpeedDps) {
    std::snprintf(err, err_len, "speed must be in (0, %.0f] deg/s", (double)kMaxSpeedDps);
    return false;
  }
  for (int i = 0; i < n_; ++i) {
    if (std::isnan(deg[i]) || deg[i] < lim_[i].min_deg || deg[i] > lim_[i].max_deg) {
      std::snprintf(err, err_len, "joint %d: %.1f outside [%.1f, %.1f]", i, (double)deg[i],
                    (double)lim_[i].min_deg, (double)lim_[i].max_deg);
      return false;
    }
  }
  for (int i = 0; i < n_; ++i) tgt_[i] = deg[i];
  speed_dps_ = speed_dps;
  if (err_len) err[0] = '\0';
  return true;
}

void ServoPlanner::tick(uint32_t dt_ms) {
  float step = speed_dps_ * (float)dt_ms / 1000.0f;
  for (int i = 0; i < n_; ++i) {
    float d = tgt_[i] - cur_[i];
    if (std::fabs(d) <= step) cur_[i] = tgt_[i];
    else cur_[i] += (d > 0 ? step : -step);
  }
}

void ServoPlanner::hold() {
  for (int i = 0; i < n_; ++i) tgt_[i] = cur_[i];
}

void ServoPlanner::goHome(float speed_dps) {
  for (int i = 0; i < n_; ++i) tgt_[i] = lim_[i].home_deg;
  if (speed_dps > 0.0f && speed_dps <= kMaxSpeedDps) speed_dps_ = speed_dps;
}

bool ServoPlanner::moving() const {
  for (int i = 0; i < n_; ++i)
    if (cur_[i] != tgt_[i]) return true;
  return false;
}

uint16_t angleToPulseUs(float deg, const JointLimit& j) {
  if (deg < 0.0f) deg = 0.0f;
  if (deg > 180.0f) deg = 180.0f;
  return (uint16_t)std::lround(j.min_us + (deg / 180.0f) * (float)(j.max_us - j.min_us));
}

uint16_t pulseUsToTicks(uint16_t us, float pwm_hz) {
  // PCA9685: 4096 ticks per period; period = 1e6 / pwm_hz microseconds.
  float ticks = (float)us * 4096.0f * pwm_hz / 1e6f;
  if (ticks > 4095.0f) ticks = 4095.0f;
  return (uint16_t)std::lround(ticks);
}

}  // namespace bb
