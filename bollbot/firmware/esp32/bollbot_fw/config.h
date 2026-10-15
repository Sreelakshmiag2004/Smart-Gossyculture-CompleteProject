// BollBot ESP32 pin map and limits. ESP32 DevKit V1 (38-pin).
// Avoid strapping pins 0, 2*, 12, 15 for inputs. (*2 = on-board LED only.)
#pragma once
#include "core.h"

// ---- outputs
#define PIN_PUMP        26   // to MOSFET gate (logic-level N-MOSFET, e.g. IRLZ44N) / relay IN; HIGH = on
                             // fit a 10k pull-down gate->GND so the pump stays off while the ESP32 boots
#define PIN_SERVO_OE    4    // PCA9685 OE (active LOW). Driven HIGH = all servo outputs off
#define PIN_BLOWER      25   // picking-head vacuum blower MOSFET (10k pull-down), HIGH = on
#define PIN_ROLLERS     27   // picking-head roller motors MOSFET (10k pull-down), HIGH = on
#define PIN_LED         2    // on-board LED: blinks while a spray runs

// ---- safety inputs (INPUT_PULLUP)
#define PIN_DEADMAN     32   // momentary button to GND: LOW = held
#define PIN_ESTOP_SENSE 33   // E-stop NC auxiliary contact to GND: LOW = normal, HIGH = pressed or cable cut
// The E-stop's main contact ALSO cuts the 12 V pump/servo supply in hardware.
// This input only lets the firmware report it; it is not the only protection.

// ---- ultrasonic HC-SR04 (5 V). ECHO through a divider (1k / 2k) to 3.3 V!
#define PIN_US_FRONT_TRIG 18
#define PIN_US_FRONT_ECHO 19
#define PIN_US_SIDE_TRIG  16
#define PIN_US_SIDE_ECHO  17
// Mount FRONT facing along the row (direction of travel) and SIDE facing the
// path / next row, NOT the target plant, or the plant itself blocks spraying.

// ---- I2C to PCA9685 (default address 0x40)
#define PIN_SDA 21
#define PIN_SCL 22

// ---- timing
#define US_PERIOD_MS      60     // one sensor every 60 ms, alternating (no cross-talk)
#define US_TIMEOUT_US     30000  // ~5 m; no echo = nothing in range
#define STATUS_PERIOD_MS  1000
#define SERVO_PERIOD_MS   20     // 50 Hz motion updates
#define RECONNECT_MS      2000

// ---- spray limits (must match bollbot/config/cart.yaml actuators.spray)
#define SPRAY_MIN_MS      100
#define SPRAY_MAX_MS      5000
#define SPRAY_COOLDOWN_MS 500

// ---- picking head: maximum ON time per command (auto-off if the Pi goes quiet)
#define EFFECTOR_MAX_MS   10000

// ---- arm joints: limits from the assembled arm, measured by hand (degrees).
// Measure each joint's safe range BEFORE the first powered test and edit here.
static const bb::JointLimit kJoints[] = {
    // min, max, home, PCA9685 channel, pulse at 0 deg, pulse at 180 deg
    {0.0f, 180.0f, 90.0f, 0, 500, 2500},   // J0 base yaw
    {20.0f, 160.0f, 90.0f, 1, 500, 2500},  // J1 shoulder
    {10.0f, 170.0f, 90.0f, 2, 500, 2500},  // J2 elbow
    {30.0f, 150.0f, 90.0f, 3, 500, 2500},  // J3 wrist
};
static const int kNumJoints = sizeof(kJoints) / sizeof(kJoints[0]);
