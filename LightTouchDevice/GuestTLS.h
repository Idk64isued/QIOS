// TLS toward the guest, terminated in the web proxy (WebProxy.swift's Guest). See GuestTLS.c for why it is C.

#include <Security/Security.h>
#include <stdbool.h>
#include <stddef.h>

typedef struct GuestTLS GuestTLS;

/// Runs the server side of a TLS 1.0+ handshake on `fd` with `identity`; NULL when it fails.
GuestTLS *_Nullable guest_tls_start(int fd, SecIdentityRef _Nonnull identity);
/// Up to `max` bytes into `buffer`; 0 at the end of input or on an error.
size_t guest_tls_read(GuestTLS *_Nonnull tls, void *_Nonnull buffer, size_t max);
/// All of `bytes`; false when the connection fails first.
bool guest_tls_write(GuestTLS *_Nonnull tls, const void *_Nonnull bytes, size_t count);
/// Sends close_notify and frees `tls` (not the descriptor).
void guest_tls_close(GuestTLS *_Nonnull tls);
