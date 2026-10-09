#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

typedef struct {
    const char *name;
    const char *public_path;
    uint16_t public_port;
    uint16_t worker_port;
    const char *magic;
} M7BridgeChannel;

typedef struct {
    int public_client;
    int camera_worker;
} M7BridgePair;

typedef struct {
    M7BridgeChannel *channel;
    int listener;
    pthread_mutex_t mutex;
    pthread_cond_t available;
    int workers[16];
    size_t worker_count;
} M7WorkerPool;

static const uint8_t M7BridgeActivation[] = "M7-BRIDGE-CLIENT-1\n";

static int m7_send_all(int fd, const uint8_t *bytes, size_t length) {
    size_t sent = 0;
    while (sent < length) {
        ssize_t count = send(fd, bytes + sent, length - sent, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        sent += (size_t)count;
    }
    return 0;
}

static int m7_read_exact(int fd, uint8_t *bytes, size_t length) {
    size_t received = 0;
    while (received < length) {
        ssize_t count = recv(fd, bytes + received, length - received, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        received += (size_t)count;
    }
    return 0;
}

static int m7_unix_listener(const char *path) {
    if (!path || strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    unlink(path);
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
#if defined(__APPLE__)
    address.sun_len = sizeof(address);
#endif
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, path, sizeof(address.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        chmod(path, S_IRUSR | S_IWUSR) != 0 || listen(fd, 8) != 0) {
        int code = errno;
        close(fd);
        unlink(path);
        errno = code;
        return -1;
    }
    return fd;
}

static int m7_tcp_listener(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int enabled = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
#if defined(__APPLE__)
    address.sin_len = sizeof(address);
#endif
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(UINT32_C(0x7f000001));
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 8) != 0) {
        int code = errno;
        close(fd);
        errno = code;
        return -1;
    }
    return fd;
}

static int m7_accept_worker(int listener, const char *magic) {
    const size_t magic_length = strlen(magic);
    for (;;) {
        int worker = accept(listener, NULL, NULL);
        if (worker < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        struct timeval timeout = {.tv_sec = 2, .tv_usec = 0};
        setsockopt(worker, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        uint8_t received[64] = {0};
        if (magic_length <= sizeof(received) &&
            m7_read_exact(worker, received, magic_length) == 0 &&
            memcmp(received, magic, magic_length) == 0) {
            timeout.tv_sec = 0;
            setsockopt(worker, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            return worker;
        }
        close(worker);
    }
}

static int m7_worker_alive(int worker) {
    struct pollfd descriptor = {.fd = worker, .events = POLLIN};
    int result = poll(&descriptor, 1, 0);
    if (result < 0) return errno == EINTR;
    if (result == 0) return 1;
    if (descriptor.revents & (POLLHUP | POLLERR | POLLNVAL)) return 0;
    if (descriptor.revents & POLLIN) {
        uint8_t byte = 0;
        ssize_t count = recv(worker, &byte, 1, MSG_PEEK);
        if (count == 0) return 0;
        if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) return 0;
    }
    return 1;
}

static void *m7_worker_accept_main(void *context) {
    M7WorkerPool *pool = context;
    for (;;) {
        int worker = m7_accept_worker(pool->listener, pool->channel->magic);
        if (worker < 0) break;
        pthread_mutex_lock(&pool->mutex);
        if (pool->worker_count == sizeof(pool->workers) / sizeof(pool->workers[0])) {
            close(pool->workers[0]);
            memmove(pool->workers, pool->workers + 1,
                (pool->worker_count - 1) * sizeof(pool->workers[0]));
            --pool->worker_count;
        }
        pool->workers[pool->worker_count++] = worker;
        pthread_cond_signal(&pool->available);
        pthread_mutex_unlock(&pool->mutex);
    }
    return NULL;
}

static int m7_take_live_worker(M7WorkerPool *pool) {
    for (;;) {
        pthread_mutex_lock(&pool->mutex);
        while (pool->worker_count == 0) pthread_cond_wait(&pool->available, &pool->mutex);
        int worker = pool->workers[0];
        memmove(pool->workers, pool->workers + 1,
            (pool->worker_count - 1) * sizeof(pool->workers[0]));
        --pool->worker_count;
        pthread_mutex_unlock(&pool->mutex);
        if (m7_worker_alive(worker) && m7_send_all(worker, M7BridgeActivation,
            sizeof(M7BridgeActivation) - 1) == 0) return worker;
        close(worker);
    }
}

static void *m7_proxy_pair(void *context) {
    M7BridgePair *pair = context;
    int left = pair->public_client;
    int right = pair->camera_worker;
    free(pair);
    int open_left = 1;
    int open_right = 1;
    uint8_t buffer[16 * 1024];
    while (open_left || open_right) {
        struct pollfd descriptors[2] = {
            {.fd = left, .events = open_left ? POLLIN : 0},
            {.fd = right, .events = open_right ? POLLIN : 0},
        };
        int result = poll(descriptors, 2, -1);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) break;
        if (open_left && (descriptors[0].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t count = recv(left, buffer, sizeof(buffer), 0);
            if (count > 0 && m7_send_all(right, buffer, (size_t)count) == 0) {
                /* forwarded */
            } else {
                open_left = 0;
                shutdown(right, SHUT_WR);
            }
        }
        if (open_right && (descriptors[1].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t count = recv(right, buffer, sizeof(buffer), 0);
            if (count > 0 && m7_send_all(left, buffer, (size_t)count) == 0) {
                /* forwarded */
            } else {
                open_right = 0;
                shutdown(left, SHUT_WR);
            }
        }
    }
    close(left);
    close(right);
    return NULL;
}

static void *m7_channel_main(void *context) {
    M7BridgeChannel *channel = context;
    int public_listener = m7_unix_listener(channel->public_path);
    if (public_listener < 0) {
        fprintf(stderr, "manual7bridge: %s Unix bind failed: %s\n", channel->name, strerror(errno));
        return NULL;
    }
    int worker_listener = m7_tcp_listener(channel->worker_port);
    if (worker_listener < 0) {
        fprintf(stderr, "manual7bridge: %s TCP bind failed: %s\n", channel->name, strerror(errno));
        close(public_listener);
        unlink(channel->public_path);
        return NULL;
    }
    int public_tcp_listener = m7_tcp_listener(channel->public_port);
    if (public_tcp_listener < 0) {
        fprintf(stderr, "manual7bridge: %s public TCP bind failed: %s\n",
            channel->name, strerror(errno));
        close(public_listener);
        close(worker_listener);
        unlink(channel->public_path);
        return NULL;
    }
    fprintf(stderr, "manual7bridge: %s ready at %s and 127.0.0.1:%u via worker %u\n",
        channel->name, channel->public_path, channel->public_port, channel->worker_port);
    M7WorkerPool pool = {.channel = channel, .listener = worker_listener,
        .mutex = PTHREAD_MUTEX_INITIALIZER, .available = PTHREAD_COND_INITIALIZER,
        .worker_count = 0};
    pthread_t worker_thread;
    if (pthread_create(&worker_thread, NULL, m7_worker_accept_main, &pool) != 0) {
        close(public_listener);
        close(worker_listener);
        unlink(channel->public_path);
        return NULL;
    }
    for (;;) {
        struct pollfd public_descriptors[2] = {
            {.fd = public_listener, .events = POLLIN},
            {.fd = public_tcp_listener, .events = POLLIN},
        };
        int ready = poll(public_descriptors, 2, -1);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) break;
        int selected = (public_descriptors[0].revents & POLLIN) ? public_listener :
            (public_descriptors[1].revents & POLLIN) ? public_tcp_listener : -1;
        if (selected < 0) continue;
        int client = accept(selected, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            break;
        }
        int worker = m7_take_live_worker(&pool);
        M7BridgePair *pair = calloc(1, sizeof(*pair));
        if (!pair) {
            close(client);
            close(worker);
            continue;
        }
        pair->public_client = client;
        pair->camera_worker = worker;
        pthread_t thread;
        if (pthread_create(&thread, NULL, m7_proxy_pair, pair) == 0) pthread_detach(thread);
        else {
            close(client);
            close(worker);
            free(pair);
        }
    }
    close(public_listener);
    close(public_tcp_listener);
    close(worker_listener);
    unlink(channel->public_path);
    return NULL;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    const char *api_path = argc > 1 ? argv[1] : "/var/tmp/Manual7-api.sock";
    const char *webcam_path = argc > 2 ? argv[2] : "/var/tmp/Manual7-webcam.sock";
    long api_port = argc > 3 ? strtol(argv[3], NULL, 10) : 27837;
    long webcam_port = argc > 4 ? strtol(argv[4], NULL, 10) : 27838;
    long api_public_port = argc > 5 ? strtol(argv[5], NULL, 10) : 27839;
    long webcam_public_port = argc > 6 ? strtol(argv[6], NULL, 10) : 27840;
    if (api_port < 1 || api_port > 65535 || webcam_port < 1 || webcam_port > 65535 ||
        api_public_port < 1 || api_public_port > 65535 ||
        webcam_public_port < 1 || webcam_public_port > 65535 ||
        api_port == webcam_port || api_public_port == webcam_public_port ||
        api_port == api_public_port || api_port == webcam_public_port ||
        webcam_port == api_public_port || webcam_port == webcam_public_port) {
        fprintf(stderr, "usage: manual7bridge [api-socket webcam-socket api-worker-port "
            "webcam-worker-port api-public-port webcam-public-port]\n");
        return 64;
    }
    M7BridgeChannel channels[2] = {
        {.name = "api", .public_path = api_path, .public_port = (uint16_t)api_public_port,
            .worker_port = (uint16_t)api_port,
            .magic = "M7-CAMERA-API-1\n"},
        {.name = "webcam", .public_path = webcam_path, .public_port = (uint16_t)webcam_public_port,
            .worker_port = (uint16_t)webcam_port,
            .magic = "M7-CAMERA-WEBCAM-1\n"},
    };
    pthread_t threads[2];
    if (pthread_create(&threads[0], NULL, m7_channel_main, &channels[0]) != 0 ||
        pthread_create(&threads[1], NULL, m7_channel_main, &channels[1]) != 0) {
        fprintf(stderr, "manual7bridge: could not start channel threads\n");
        return 1;
    }
    pthread_join(threads[0], NULL);
    pthread_join(threads[1], NULL);
    return 1;
}
