// build-package-native.sh's check of libimobiledevice-reply-limits.patch, built in libimobiledevice's source tree
// against the library just built: a plist service reply that declares more than 32 MiB is refused before the host
// allocates it, and a small one still arrives. A socket pair stands in for the device's connection.
#include <config.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <arpa/inet.h>

#include "idevice.h"
#include "property_list_service.h"
#include "service.h"

static void reply(int fd, uint32_t size) // an XML plist of exactly `size` bytes, after its length
{
    const char *head = "<?xml version=\"1.0\"?><plist version=\"1.0\"><string>", *tail = "</string></plist>";
    char *body = malloc(size);
    memset(body, 'a', size);
    memcpy(body, head, strlen(head));
    memcpy(body + size - strlen(tail), tail, strlen(tail));
    uint32_t length = htonl(size);
    if (write(fd, &length, 4) == 4) {
        for (uint32_t sent = 0; sent < size;) {
            ssize_t n = write(fd, body + sent, size - sent);
            if (n <= 0)
                break;
            sent += (uint32_t)n;
        }
    }
    free(body);
}

int main(void) {
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0)
        return 2;
    signal(SIGPIPE, SIG_IGN);
    pid_t writer = fork();
    if (writer == 0) {
        close(fds[0]);
        reply(fds[1], 1024);
        reply(fds[1], 40 << 20);
        _exit(0);
    }
    close(fds[1]);
    struct idevice_connection_private connection = {.type = CONNECTION_USBMUXD, .data = (void *)(uintptr_t)fds[0]};
    struct service_client_private service = {.connection = &connection};
    struct property_list_service_client_private client = {.parent = &service};
    plist_t small = NULL, large = NULL;
    property_list_service_error_t first = property_list_service_receive_plist(&client, &small);
    property_list_service_error_t second = property_list_service_receive_plist(&client, &large);
    close(fds[0]);
    kill(writer, SIGKILL);
    waitpid(writer, NULL, 0);
    if (first != PROPERTY_LIST_SERVICE_E_SUCCESS || !small) {
        fprintf(stderr, "a 1 KiB plist reply was not received (%d)\n", first);
        return 1;
    }
    if (second != PROPERTY_LIST_SERVICE_E_PLIST_ERROR || large) {
        fprintf(stderr,
                "a 40 MiB plist reply was not refused (%d): libimobiledevice-reply-limits.patch is not in effect\n",
                second);
        return 1;
    }
    return 0;
}
