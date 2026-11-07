// The services helper's C: libimobiledevice and libplist, which it links (the Swift engine under
// LIGHTTOUCH_SERVICES calls them directly), and its two lockdown write operations.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wdocumentation-deprecated-sync"
#pragma clang diagnostic ignored "-Wstrict-prototypes"
#include <libimobiledevice/afc.h>
#include <libimobiledevice/house_arrest.h>
#include <libimobiledevice/installation_proxy.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/mobile_image_mounter.h>
#include <libimobiledevice/notification_proxy.h>
#include <libimobiledevice/property_list_service.h>
#include <libimobiledevice/sbservices.h>
#include <libimobiledevice/service.h>
#include <plist/plist.h>
#pragma clang diagnostic pop

// The lockdown writes the services helper runs as operations of its own child process
// (`LightTouchServices lockdown-tz …`, `LightTouchServices lockdown-mcinstall …`): lockdownd_set_value made
// in-process against 3.1.3's lockdownd corrupts the caller's heap, so each write gets a process to itself.
// argv[0] is the operation's name; the exit status is the operation's.
int ltm_lockdown_tz(int argc, char **argv);
int ltm_lockdown_mcinstall(int argc, char **argv);
int ltm_lockdown_ddi(int argc, char **argv);
int ltm_lockdown_ax(int argc, char **argv);
