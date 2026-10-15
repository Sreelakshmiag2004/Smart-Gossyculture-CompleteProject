// Copy this file to secrets.h and fill in. secrets.h is git-ignored.
#pragma once
#define WIFI_SSID     "bollbot-cart"   // the Pi's Wi-Fi hotspot
#define WIFI_PASSWORD "change-me"
#define MQTT_HOST     "10.42.0.1"      // the Pi's address on its own hotspot
#define MQTT_PORT     1883
#define MQTT_USER     "esp32"
#define MQTT_PASSWORD "change-me"
#define CART_ID       "cart01"         // must match cart_id in bollbot/config/cart.yaml
