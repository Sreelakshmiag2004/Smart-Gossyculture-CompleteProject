// Host unit tests for the firmware core. Build and run on a PC:
//   g++ -std=c++17 -Wall -Wextra -Werror -I../bollbot_fw test_core.cpp ../bollbot_fw/core.cpp -o t && ./t
#include <cmath>
#include <cstdio>
#include <cstring>

#include "core.h"

using namespace bb;

static int g_fail = 0, g_pass = 0;
#define CHECK(cond)                                                       \
  do {                                                                    \
    if (cond) { ++g_pass; }                                               \
    else { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

static SafetyInputs safe() { return {false, true, -1.0f, 350.0f, 100, true}; }

static void test_safety_gate() {
  SafetyLimits lim;
  CHECK(sprayBlock(safe(), lim) == Block::NONE);
  SafetyInputs s = safe(); s.estop_pressed = true; s.deadman_held = false;
  CHECK(sprayBlock(s, lim) == Block::ESTOP);                 // E-stop reported first
  s = safe(); s.deadman_held = false;  CHECK(sprayBlock(s, lim) == Block::DEADMAN);
  s = safe(); s.link_up = false;       CHECK(sprayBlock(s, lim) == Block::LINK_DOWN);
  s = safe(); s.us_age_ms = 501;       CHECK(sprayBlock(s, lim) == Block::SENSOR_STALE);
  s = safe(); s.us_front_cm = 150;     CHECK(sprayBlock(s, lim) == Block::PERSON_FRONT);
  s = safe(); s.us_side_cm = 199.9f;   CHECK(sprayBlock(s, lim) == Block::PERSON_SIDE);
  s = safe(); s.us_side_cm = 200.0f;   CHECK(sprayBlock(s, lim) == Block::NONE);   // exactly 2 m ok
  s = safe(); s.us_front_cm = NAN;     CHECK(sprayBlock(s, lim) == Block::PERSON_FRONT);
  CHECK(std::strcmp(blockName(Block::DEADMAN), "deadman_released") == 0);
}

static void test_spray_completes() {
  SprayController sc(100, 5000, 500);
  SprayEvent ev;
  CHECK(sc.start("s1", 2700, 1000, Block::NONE) == StartResult::OK);
  CHECK(sc.tick(1000, Block::NONE, &ev) && !ev.valid);
  CHECK(sc.remainingMs(2000) == 1700);
  CHECK(sc.tick(3699, Block::NONE, &ev));                    // still on at 2699 ms
  CHECK(!sc.tick(3700, Block::NONE, &ev));                   // off at exactly 2700 ms
  CHECK(ev.valid && ev.completed && ev.ms_on == 2700 && std::strcmp(ev.id, "s1") == 0);
  CHECK(sc.start("s2", 1000, 3900, Block::NONE) == StartResult::BUSY);   // cooldown
  sc.tick(4200, Block::NONE, &ev);
  CHECK(sc.start("s2", 1000, 4200, Block::NONE) == StartResult::OK);
}

static void test_spray_aborts_instantly() {
  SprayController sc;
  SprayEvent ev;
  sc.start("s1", 3000, 0, Block::NONE);
  CHECK(sc.tick(800, Block::NONE, &ev));
  CHECK(!sc.tick(900, Block::DEADMAN, &ev));                 // operator let go
  CHECK(ev.valid && !ev.completed && ev.ms_on == 900 && ev.reason == Block::DEADMAN);
  CHECK(!sc.pumpOn());
}

static void test_spray_rejections() {
  SprayController sc(100, 5000, 0);
  Block why;
  CHECK(sc.start("x", 50, 0, Block::NONE) == StartResult::BAD_DURATION);
  CHECK(sc.start("x", 6000, 0, Block::NONE) == StartResult::BAD_DURATION);
  CHECK(sc.start("", 1000, 0, Block::NONE) == StartResult::BAD_ID);
  CHECK(sc.start("0123456789012345678901234567890123", 1000, 0, Block::NONE) == StartResult::BAD_ID);
  CHECK(sc.start("x", 1000, 0, Block::PERSON_SIDE, &why) == StartResult::BLOCKED && why == Block::PERSON_SIDE);
  CHECK(sc.start("x", 1000, 0, Block::NONE) == StartResult::OK);
  CHECK(sc.start("y", 1000, 10, Block::NONE) == StartResult::BUSY);
}

static void test_spray_millis_wraparound() {
  SprayController sc(100, 5000, 0);
  SprayEvent ev;
  uint32_t t0 = 0xFFFFFF00u;                                   // 256 ms before wrap
  sc.start("w", 1000, t0, Block::NONE);
  CHECK(sc.tick(t0 + 500, Block::NONE, &ev));                  // wrapped, still on
  CHECK(!sc.tick(t0 + 1000, Block::NONE, &ev) && ev.completed && ev.ms_on == 1000);
}

static const JointLimit kArm[4] = {
    {0, 180, 90, 0}, {20, 160, 90, 1}, {10, 170, 90, 2}, {30, 150, 90, 3}};

static void test_servo_limits_and_motion() {
  ServoPlanner p(kArm, 4);
  char err[64];
  float bad[4] = {90, 10, 90, 90};                             // joint 1 below 20
  CHECK(!p.setTarget(bad, 4, 30, err, sizeof err) && std::strstr(err, "joint 1"));
  CHECK(p.target(1) == 90);                                    // unchanged after rejection
  float three[3] = {90, 90, 90};
  CHECK(!p.setTarget(three, 3, 30, err, sizeof err));
  float ok[4] = {120, 60, 90, 90};
  CHECK(!p.setTarget(ok, 4, 500, err, sizeof err));            // too fast
  CHECK(p.setTarget(ok, 4, 30, err, sizeof err));
  p.tick(500);                                                 // 15 deg max per joint
  CHECK(std::fabs(p.current(0) - 105) < 1e-3 && std::fabs(p.current(1) - 75) < 1e-3);
  p.tick(1000);
  CHECK(p.current(0) == 120 && p.current(1) == 60 && !p.moving());
  p.goHome(60);
  p.tick(100);
  p.hold();                                                    // E-stop mid-move
  float where = p.current(0);
  p.tick(1000);
  CHECK(p.current(0) == where && !p.moving());
}

static void test_pulses() {
  JointLimit j{0, 180, 90, 0, 500, 2500};
  CHECK(angleToPulseUs(0, j) == 500);
  CHECK(angleToPulseUs(90, j) == 1500);
  CHECK(angleToPulseUs(180, j) == 2500);
  CHECK(angleToPulseUs(200, j) == 2500);                       // clamped to servo range
  CHECK(pulseUsToTicks(1500) == 307);                          // 1500 us at 50 Hz
  CHECK(pulseUsToTicks(20000) == 4095);
}

static void test_motion_gate_and_effector() {
  SafetyInputs s = safe();
  s.us_front_cm = 50;                                          // person guard does NOT block motion
  CHECK(motionBlock(s) == Block::NONE);
  s.deadman_held = false;  CHECK(motionBlock(s) == Block::DEADMAN);
  s = safe(); s.estop_pressed = true; CHECK(motionBlock(s) == Block::ESTOP);
  s = safe(); s.link_up = false;      CHECK(motionBlock(s) == Block::LINK_DOWN);

  EffectorController e(10000);
  Block why;
  CHECK(e.start(0, 0, Block::NONE) == StartResult::BAD_DURATION);
  CHECK(e.start(20000, 0, Block::NONE) == StartResult::BAD_DURATION);
  CHECK(e.start(3000, 0, Block::DEADMAN, &why) == StartResult::BLOCKED && why == Block::DEADMAN);
  CHECK(e.start(3000, 1000, Block::NONE) == StartResult::OK);
  CHECK(e.tick(3999, Block::NONE) && e.remainingMs(3000) == 1000);
  CHECK(!e.tick(4000, Block::NONE));                           // auto-off after 3 s
  e.start(3000, 5000, Block::NONE);
  CHECK(!e.tick(5100, Block::LINK_DOWN));                      // stops at once
  e.start(3000, 6000, Block::NONE);
  e.stop();
  CHECK(!e.on() && !e.tick(6001, Block::NONE));
}

int main() {
  test_motion_gate_and_effector();
  test_safety_gate();
  test_spray_completes();
  test_spray_aborts_instantly();
  test_spray_rejections();
  test_spray_millis_wraparound();
  test_servo_limits_and_motion();
  test_pulses();
  std::printf("%d passed, %d failed\n", g_pass, g_fail);
  return g_fail ? 1 : 0;
}
