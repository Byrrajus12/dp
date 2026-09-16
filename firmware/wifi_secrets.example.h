#pragma once

#define PET_WIFI_AUTH_PERSONAL 1
#define PET_WIFI_AUTH_ENTERPRISE_PEAP 2

#define PET_WIFI_AUTH_MODE PET_WIFI_AUTH_PERSONAL

#define WIFI_SSID "your-ssid"
#define WIFI_PASSWORD "your-password"

// Enterprise PEAP only. If your provider gives one email/identity, use it for
// both values. Replace nullptr with a PEM CA certificate string to validate the
// authentication server; omitting CA validation is vulnerable to evil twins.
#define WIFI_EAP_IDENTITY "your-identity-or-email"
#define WIFI_EAP_USERNAME "your-username-or-email"
#define WIFI_EAP_CA_CERT nullptr
