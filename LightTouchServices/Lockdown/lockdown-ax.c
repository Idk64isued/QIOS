/*
 * LightTouchServices lockdown-ax <Key>=0|1 ...
 * LightTouchServices lockdown-ax --get <Key>
 *
 * Turn the guest's own accessibility features on or off the way iTunes'
 * Configure Universal Access did (iOS 3.0 to 7.1.2): each key, such as
 * VoiceOverTouchEnabledByiTunes, set as a boolean in lockdown's
 * com.apple.Accessibility domain, then com.apple.accessibility.status.itunes
 * posted through notification_proxy. SpringBoard's handler (the
 * AccessibilitySettingsLoader bundle to 5.1.1, SBAXServer.bundle on 6.x, the
 * shared cache on 7.x) reads those keys back and calls the same
 * libAccessibility setters Settings does, as mobile and live: VoiceOver's
 * launch, SpringBoard's inverted display, Zoom.
 *
 * --get prints the key's value, 1 or 0 (0 when unset): iPhone OS 3.0 to 3.1.3's
 * handler inverts the display through SpringBoard alone, so White on Black's
 * state there is this key, which the handler and Settings both keep.
 *
 * Its own child process like lockdown-tz, for the same reason: lockdown writes
 * made in-process from the app have corrupted its heap. Finds the device via
 * USBMUXD_SOCKET_ADDRESS. Exits 0 when every key was set and the notification
 * posted, or the value was read.
 */
#include "Lockdown.h"
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/notification_proxy.h>
#include <plist/plist.h>
#include <stdio.h>
#include <string.h>

int ltm_lockdown_ax(int argc, char **argv) {
    idevice_t dev = NULL;
    lockdownd_client_t ld = NULL;
    np_client_t np = NULL;
    int get = argc == 3 && !strcmp(argv[1], "--get");

    if (argc < 2) {
        fprintf(stderr, "usage: lockdown-ax <Key>=0|1 ... | --get <Key>\n");
        return 2;
    }
    for (int i = 1; i < argc && !get; i++) {
        const char *eq = strchr(argv[i], '=');
        if (!eq || eq == argv[i] || (strcmp(eq, "=0") && strcmp(eq, "=1"))) {
            fprintf(stderr, "lockdown-ax: %s is not Key=0 or Key=1\n", argv[i]);
            return 2;
        }
    }
    if (idevice_new(&dev, NULL) != IDEVICE_E_SUCCESS ||
        lockdownd_client_new_with_handshake(dev, &ld, "lockdown-ax") != LOCKDOWN_E_SUCCESS) {
        fprintf(stderr, "cannot reach the device's lockdown\n");
        return 1;
    }
    if (get) {
        plist_t value = NULL;
        uint8_t on = 0;
        if (lockdownd_get_value(ld, "com.apple.Accessibility", argv[2], &value) == LOCKDOWN_E_SUCCESS && value &&
            plist_get_node_type(value) == PLIST_BOOLEAN)
            plist_get_bool_val(value, &on);
        printf("%d\n", on ? 1 : 0);
        return 0;
    }
    for (int i = 1; i < argc; i++) {
        char key[128];
        size_t n = strchr(argv[i], '=') - argv[i];
        if (n >= sizeof key)
            n = sizeof key - 1;
        memcpy(key, argv[i], n);
        key[n] = 0;
        int on = argv[i][strlen(argv[i]) - 1] == '1';
        lockdownd_error_t e = lockdownd_set_value(ld, "com.apple.Accessibility", key, plist_new_bool(on));
        if (e != LOCKDOWN_E_SUCCESS) {
            fprintf(stderr, "lockdown-ax: setting %s failed: %d\n", key, e);
            return 1;
        }
    }
    if (np_client_start_service(dev, &np, "lockdown-ax") != NP_E_SUCCESS ||
        np_post_notification(np, "com.apple.accessibility.status.itunes") != NP_E_SUCCESS) {
        fprintf(stderr, "lockdown-ax: notification_proxy did not take the notification\n");
        return 1;
    }
    np_client_free(np);
    lockdownd_client_free(ld);
    idevice_free(dev);
    return 0;
}
