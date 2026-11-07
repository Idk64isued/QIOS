/*
 * LightTouchServices lockdown-ddi <DeveloperDiskImage.dmg> <DeveloperDiskImage.dmg.signature>
 *
 * Mount Apple's Developer Disk Image (from an Xcode of the device's era) through lockdown's stock
 * com.apple.mobile.mobile_image_mounter, as Xcode did on connecting a device: Settings then shows Developer (its
 * settings bundle is on the image) and the image's lockdown services start. The device checks the image against
 * Apple's signature. Before iOS 7 the image goes up by AFC to PublicStaging; from 7 the mounter takes it itself
 * (ReceiveBytes), as ideviceimagemounter does. Nothing to do when a Developer image is mounted already.
 *
 * Its own child process like lockdown-tz. Finds the device via USBMUXD_SOCKET_ADDRESS. Prints "mounted" or
 * "already mounted" and exits 0, or prints the mounter's error and exits 1 (2: bad arguments or files).
 */
#include "Lockdown.h"
#include <libimobiledevice/afc.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/mobile_image_mounter.h>
#include <plist/plist.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define STAGED "/private/var/mobile/Media/PublicStaging/staging.dimage"

static unsigned char *slurp(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    long n;
    unsigned char *data;
    if (!f || fseek(f, 0, SEEK_END) || (n = ftell(f)) <= 0 || n > (1L << 30)) {
        if (f)
            fclose(f);
        return NULL;
    }
    rewind(f);
    data = malloc((size_t)n);
    if (!data || fread(data, 1, (size_t)n, f) != (size_t)n) {
        free(data);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *size = (size_t)n;
    return data;
}

typedef struct {
    const unsigned char *data;
    size_t size, sent;
} Reader;

static ssize_t feed(void *buffer, size_t length, void *user) {
    Reader *r = user;
    size_t n = r->size - r->sent < length ? r->size - r->sent : length;
    memcpy(buffer, r->data + r->sent, n);
    r->sent += n;
    return (ssize_t)n;
}

/* The mounter's answer: NULL for Status Complete, else its error (the caller frees it). */
static char *complete(plist_t result) {
    char *text = NULL;
    plist_t status = result ? plist_dict_get_item(result, "Status") : NULL;
    if (status)
        plist_get_string_val(status, &text);
    if (text && !strcmp(text, "Complete")) {
        free(text);
        return NULL;
    }
    plist_t error = result ? plist_dict_get_item(result, "DetailedError") : NULL;
    if (!error && result)
        error = plist_dict_get_item(result, "Error");
    free(text);
    text = NULL;
    if (error)
        plist_get_string_val(error, &text);
    return text ? text : strdup("the device didn't mount the image");
}

/* A mounted Developer image: ImagePresent (to 6.x) or a non-empty ImageSignature list (7.x). */
static int mounted(idevice_t dev) {
    mobile_image_mounter_client_t mim = NULL;
    plist_t result = NULL;
    uint8_t yes = 0;
    if (mobile_image_mounter_start_service(dev, &mim, "lockdown-ddi") != MOBILE_IMAGE_MOUNTER_E_SUCCESS)
        return 0;
    if (mobile_image_mounter_lookup_image(mim, "Developer", &result) == MOBILE_IMAGE_MOUNTER_E_SUCCESS && result) {
        plist_t present = plist_dict_get_item(result, "ImagePresent");
        plist_t signatures = plist_dict_get_item(result, "ImageSignature");
        if (present && plist_get_node_type(present) == PLIST_BOOLEAN)
            plist_get_bool_val(present, &yes);
        if (signatures && plist_get_node_type(signatures) == PLIST_ARRAY && plist_array_get_size(signatures))
            yes = 1;
    }
    plist_free(result);
    mobile_image_mounter_hangup(mim);
    mobile_image_mounter_free(mim);
    return yes;
}

int ltm_lockdown_ddi(int argc, char **argv) {
    idevice_t dev = NULL;
    lockdownd_client_t ld = NULL;
    mobile_image_mounter_client_t mim = NULL;
    plist_t version = NULL, result = NULL;
    char *text = NULL;
    size_t image_size = 0, signature_size = 0;
    unsigned char *image, *signature;

    if (argc != 3) {
        fprintf(stderr, "usage: lockdown-ddi <image.dmg> <image.dmg.signature>\n");
        return 2;
    }
    if (!(image = slurp(argv[1], &image_size)) || !(signature = slurp(argv[2], &signature_size))) {
        printf("can't read the disk image or its signature\n");
        return 2;
    }
    if (idevice_new(&dev, NULL) != IDEVICE_E_SUCCESS ||
        lockdownd_client_new_with_handshake(dev, &ld, "lockdown-ddi") != LOCKDOWN_E_SUCCESS) {
        printf("can't reach the device's lockdown\n");
        return 1;
    }
    lockdownd_get_value(ld, NULL, "ProductVersion", &version);
    if (version)
        plist_get_string_val(version, &text);
    int major = text ? atoi(text) : 0;
    lockdownd_client_free(ld);
    if (mounted(dev)) {
        printf("already mounted\n");
        return 0;
    }
    if (mobile_image_mounter_start_service(dev, &mim, "lockdown-ddi") != MOBILE_IMAGE_MOUNTER_E_SUCCESS) {
        printf("can't reach the device's image mounter\n");
        return 1;
    }
    if (major >= 7) {
        Reader r = {image, image_size, 0};
        if (mobile_image_mounter_upload_image(mim, "Developer", image_size, signature, (unsigned)signature_size, feed,
                                              &r) != MOBILE_IMAGE_MOUNTER_E_SUCCESS) {
            printf("the device didn't take the image\n");
            return 1;
        }
    } else {
        afc_client_t afc = NULL;
        uint64_t file = 0;
        if (afc_client_start_service(dev, &afc, "lockdown-ddi") != AFC_E_SUCCESS) {
            printf("can't reach the device's AFC\n");
            return 1;
        }
        afc_make_directory(afc, "PublicStaging");
        if (afc_file_open(afc, "PublicStaging/staging.dimage", AFC_FOPEN_WRONLY, &file) != AFC_E_SUCCESS) {
            printf("can't stage the image\n");
            return 1;
        }
        for (size_t sent = 0; sent < image_size;) {
            uint32_t chunk = image_size - sent < (1 << 20) ? (uint32_t)(image_size - sent) : (1 << 20), wrote = 0;
            if (afc_file_write(afc, file, (const char *)image + sent, chunk, &wrote) != AFC_E_SUCCESS || !wrote) {
                printf("staging the image failed\n");
                return 1;
            }
            sent += wrote;
        }
        afc_file_close(afc, file);
        afc_client_free(afc);
    }
    result = NULL;
    if (mobile_image_mounter_mount_image(mim, STAGED, signature, (unsigned)signature_size, "Developer", &result) !=
        MOBILE_IMAGE_MOUNTER_E_SUCCESS) {
        printf("the device didn't answer the mount\n");
        return 1;
    }
    char *error = complete(result);
    mobile_image_mounter_hangup(mim);
    mobile_image_mounter_free(mim);
    /* 4.2.1's mobile_storage_proxy stops waiting for MobileStorageMounter while it still checks the image (seconds on
       the emulated iPad), answers ImageMountFailed, and the image mounts a little later: the lookup decides. */
    for (int tries = 0; error && tries < 60; tries++) {
        sleep(1);
        if (mounted(dev)) {
            free(error);
            error = NULL;
        }
    }
    int status = error ? 1 : 0;
    printf("%s\n", error ? error : "mounted");
    free(error);
    idevice_free(dev);
    return status;
}
