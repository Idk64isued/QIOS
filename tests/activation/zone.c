/* LightTouchServices/Lockdown/lockdown-tz.c's zone and region steps against a fake lockdownd (smoke #58): the fake
 * applies a TimeZone write the way the guest does (lockdownd hands it to locationd/timed and the zone reads back a
 * few reads later). A changed zone is written once, polled until it reads back, and only then Uses24HourClock is
 * written back with the value it held, which makes SpringBoard rebuild the lock clock; a matching zone writes
 * nothing; a lockdownd without Uses24HourClock gets only the zone; a zone that never applies, or a refused write,
 * is reported. The Mac's side (ClockRegion) is LightTouchCoreTests' ClockRegionTests. */
#define lockdownd_get_value fake_get
#define lockdownd_set_value fake_set
#define usleep fake_usleep
#define main helper_main
#include "../../LightTouchServices/Lockdown/lockdown-tz.c"
#undef main
#include <assert.h>

static plist_t values;
static char pending[64], log_[256];
static int lag, reads_after_set, refused;
int fake_usleep(useconds_t us) {
    (void)us;
    return 0;
}
lockdownd_error_t fake_get(lockdownd_client_t c, const char *d, const char *key, plist_t *out) {
    (void)c;
    (void)d;
    if (!strcmp(key, "TimeZone") && pending[0] && ++reads_after_set > lag) { /* locationd relinked localtime */
        plist_dict_set_item(values, "TimeZone", plist_new_string(pending));
        pending[0] = 0;
    }
    plist_t v = plist_dict_get_item(values, key);
    *out = v ? plist_copy(v) : NULL;
    return v ? LOCKDOWN_E_SUCCESS : LOCKDOWN_E_UNKNOWN_ERROR;
}
lockdownd_error_t fake_set(lockdownd_client_t c, const char *d, const char *key, plist_t value) {
    (void)c;
    (void)d;
    strcat(log_, key);
    strcat(log_, pending[0] ? "(before the zone read back) " : " ");
    if (refused) {
        plist_free(value);
        return LOCKDOWN_E_UNKNOWN_ERROR;
    }
    if (!strcmp(key, "TimeZone")) {
        char *s = NULL;
        plist_get_string_val(value, &s);
        snprintf(pending, sizeof(pending), "%s", s);
        free(s);
        plist_free(value);
        reads_after_set = 0;
        return LOCKDOWN_E_SUCCESS;
    }
    plist_dict_set_item(values, key, value);
    return LOCKDOWN_E_SUCCESS;
}
static void fixture(const char *zone, int h24, int lag_) {
    if (values)
        plist_free(values);
    values = plist_new_dict();
    plist_dict_set_item(values, "TimeZone", plist_new_string(zone));
    if (h24 >= 0)
        plist_dict_set_item(values, "Uses24HourClock", plist_new_bool(h24));
    pending[0] = log_[0] = 0;
    lag = lag_;
    refused = 0;
}
static int is(const char *got, const char *want) {
    int ok = got && !strcmp(got, want);
    free((void *)got);
    return ok;
}
int main(void) {
    fixture("US/Pacific", 0, 3);
    assert(is(set_zone(NULL, "America/New_York"), "America/New_York"));
    printf("changed, 12-hour: %s\n", log_);
    assert(!strcmp(log_, "TimeZone Uses24HourClock "));
    assert(bool_value(NULL, "Uses24HourClock") == 0);

    fixture("US/Pacific", 1, 0);
    assert(is(set_zone(NULL, "Asia/Tokyo"), "Asia/Tokyo"));
    assert(!strcmp(log_, "TimeZone Uses24HourClock ") && bool_value(NULL, "Uses24HourClock") == 1);

    fixture("America/New_York", 0, 0);
    assert(is(set_zone(NULL, "America/New_York"), "America/New_York") && !log_[0]);

    fixture("US/Pacific", -1, 1);
    assert(is(set_zone(NULL, "Europe/Paris"), "Europe/Paris") && !strcmp(log_, "TimeZone "));

    fixture("US/Pacific", 0, 1000);
    assert(is(set_zone(NULL, "Europe/Paris"), "US/Pacific") && !strcmp(log_, "TimeZone "));

    fixture("US/Pacific", 0, 0);
    refused = 1;
    assert(set_zone(NULL, "Europe/Paris") == NULL && !strcmp(log_, "TimeZone "));
    /* The Mac's region and clock format: written only where they differ and the key exists; a locale change
     * rewrites Uses24HourClock too, which redraws the lock clock. */
    fixture("Europe/London", 0, 0);
    plist_dict_set_item(values, "Locale", plist_new_string("en_US"));
    assert(set_region(NULL, "en_GB", 1) && !strcmp(log_, "Locale Uses24HourClock "));
    assert(bool_value(NULL, "Uses24HourClock") == 1);
    log_[0] = 0;
    assert(!set_region(NULL, "en_GB", 1) && !log_[0]);
    assert(set_region(NULL, "en_GB", 0) && !strcmp(log_, "Uses24HourClock ") &&
           bool_value(NULL, "Uses24HourClock") == 0);
    log_[0] = 0;
    assert(set_region(NULL, "fr_FR", 0) && !strcmp(log_, "Locale Uses24HourClock ") &&
           bool_value(NULL, "Uses24HourClock") == 0);
    fixture("Europe/London", -1, 0); /* a lockdownd with neither key */
    assert(!set_region(NULL, "en_GB", 1) && !log_[0]);
    plist_free(values);
    puts("PASS: lockdown-tz writes a changed zone, waits for it, then refreshes the lock clock (Uses24HourClock kept); "
         "the Mac's locale and 24-hour setting only where they differ");
}
