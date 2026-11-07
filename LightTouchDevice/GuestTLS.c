// TLS toward the guest on SecureTransport, kept in C so its deprecation stays in this one file.
//
// The guests are iPhone OS 1 to iOS 7: their Safari and CFNetwork speak TLS 1.0 with the RSA and CBC cipher suites
// of the time, and the proxy answers them on the guestfwd socket it already holds, after a plain-text CONNECT.
// Network.framework can't adopt an existing descriptor or start TLS partway through a connection, so SecureTransport
// stays until the guests can be served some other way.

#include "GuestTLS.h"

#include <errno.h>
#include <stdlib.h>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

struct GuestTLS {
    SSLContextRef context;
    int fd;
};

static OSStatus guest_read(SSLConnectionRef connection, void *data, size_t *length) {
    int fd = ((const struct GuestTLS *)connection)->fd;
    size_t done = 0;
    while (done < *length) {
        ssize_t n = read(fd, (char *)data + done, *length - done);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0) {
            *length = done;
            return n == 0 ? errSSLClosedGraceful : errSSLClosedAbort;
        }
        done += (size_t)n;
    }
    return noErr;
}

static OSStatus guest_write(SSLConnectionRef connection, const void *data, size_t *length) {
    int fd = ((const struct GuestTLS *)connection)->fd;
    size_t done = 0;
    while (done < *length) {
        ssize_t n = write(fd, (const char *)data + done, *length - done);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0) {
            *length = done;
            return errSSLClosedAbort;
        }
        done += (size_t)n;
    }
    return noErr;
}

GuestTLS *guest_tls_start(int fd, SecIdentityRef identity) {
    struct GuestTLS *tls = calloc(1, sizeof *tls);
    if (!tls)
        return NULL;
    tls->fd = fd;
    tls->context = SSLCreateContext(NULL, kSSLServerSide, kSSLStreamType);
    if (!tls->context) {
        free(tls);
        return NULL;
    }
    CFArrayRef certificates = CFArrayCreate(NULL, (const void **)&identity, 1, &kCFTypeArrayCallBacks);
    OSStatus status = SSLSetIOFuncs(tls->context, guest_read, guest_write);
    if (status == noErr)
        status = SSLSetConnection(tls->context, tls);
    if (status == noErr)
        status = SSLSetProtocolVersionMin(tls->context, kTLSProtocol1); // iOS 3's Safari and CFNetwork: TLS 1.0
    if (status == noErr)
        status = SSLSetCertificate(tls->context, certificates);
    CFRelease(certificates);
    if (status == noErr) {
        do
            status = SSLHandshake(tls->context);
        while (status == errSSLWouldBlock);
    }
    if (status != noErr) {
        CFRelease(tls->context);
        free(tls);
        return NULL;
    }
    return tls;
}

size_t guest_tls_read(GuestTLS *tls, void *buffer, size_t max) {
    size_t processed = 0;
    OSStatus status = SSLRead(tls->context, buffer, max, &processed);
    return status == noErr || processed > 0 ? processed : 0;
}

bool guest_tls_write(GuestTLS *tls, const void *bytes, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        size_t processed = 0;
        if (SSLWrite(tls->context, (const char *)bytes + offset, count - offset, &processed) != noErr && processed == 0)
            return false;
        offset += processed;
    }
    return true;
}

void guest_tls_close(GuestTLS *tls) {
    SSLClose(tls->context);
    CFRelease(tls->context);
    free(tls);
}

#pragma clang diagnostic pop
