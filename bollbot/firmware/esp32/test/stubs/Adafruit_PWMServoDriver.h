#pragma once
#include <map>
#include "Wire.h"
#include <cstdint>
extern std::map<int,int> g_pwm;
class Adafruit_PWMServoDriver { public: Adafruit_PWMServoDriver(uint8_t, TwoWire&) {} void begin(){} void setOscillatorFrequency(uint32_t){} void setPWMFreq(float){} void setPWM(uint8_t ch, uint16_t, uint16_t off){ g_pwm[ch]=off; } };
