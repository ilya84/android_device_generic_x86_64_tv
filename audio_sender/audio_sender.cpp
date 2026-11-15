/*
 * audio-rtp-sender — capture the Android playback mix (REMOTE_SUBMIX) and
 * stream it as RTP L16/48000/stereo to the audiohub receiver.
 *
 * This is intentionally a small native daemon: it has no UI, starts from
 * init, and restarts automatically if audioflinger/audioserver goes away.
 *
 * RTP payload is big-endian signed 16-bit PCM (RFC 3551 L16), mono/stereo
 * determined by the negotiated receiver (we always send stereo).
 */

#include <arpa/inet.h>
#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <math.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <string>

#include <android-base/properties.h>
#include <android/content/AttributionSourceState.h>
#include <binder/Binder.h>
#include <log/log.h>
#include <media/AudioRecord.h>
#include <system/audio.h>

using android::AudioRecord;
using android::BBinder;
using android::content::AttributionSourceState;
using android::sp;
using android::status_t;

namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kChannels = 2;
constexpr uint32_t kBytesPerSample = 2;
constexpr uint32_t kFrameBytes = kChannels * kBytesPerSample;
constexpr uint8_t kPayloadType = 10;  // RTP static PT 10: L16 stereo
constexpr uint32_t kDefaultSsrc = 0x4c4f5354;  // "LOST"
constexpr size_t kMaxPacketFrames = 480;        // 10 ms upper bound

// Runtime control/status properties.  TvSettings writes kPropEnabled;
// the daemon writes kPropState/kPropStats for the UI.
constexpr char kPropEnabled[] = "persist.sys.audio_rtp.enabled";
constexpr char kPropHost[] = "persist.sys.audio_rtp.host";
constexpr char kPropPort[] = "persist.sys.audio_rtp.port";
constexpr char kPropState[] = "sys.audio_rtp.state";
constexpr char kPropStats[] = "sys.audio_rtp.stats";

std::atomic<bool> g_stop{false};

void handle_signal(int) {
    g_stop.store(true);
}

struct Config {
    std::string host = "192.168.5.150";
    uint16_t port = 5004;
    uint32_t ssrc = kDefaultSsrc;
    uint32_t packet_ms = 5;
    bool verbose = false;
};

void usage(const char* prog) {
    fprintf(stderr,
            "usage: %s [--host ADDR] [--port PORT] [--ssrc HEX] "
            "[--packet-ms 5|10] [--verbose]\n",
            prog);
}

bool parse_uint(const char* text, unsigned long max, unsigned long* out) {
    if (text == nullptr || *text == '\0') return false;
    char* end = nullptr;
    errno = 0;
    unsigned long value = strtoul(text, &end, 0);
    if (errno != 0 || end == text || *end != '\0' || value > max) return false;
    *out = value;
    return true;
}

bool parse_args(int argc, char** argv, Config* cfg) {
    static const option kOptions[] = {
            {"host", required_argument, nullptr, 'h'},
            {"port", required_argument, nullptr, 'p'},
            {"ssrc", required_argument, nullptr, 's'},
            {"packet-ms", required_argument, nullptr, 'm'},
            {"verbose", no_argument, nullptr, 'v'},
            {"help", no_argument, nullptr, '?'},
            {nullptr, 0, nullptr, 0},
    };

    int c;
    while ((c = getopt_long(argc, argv, "h:p:s:m:v?", kOptions, nullptr)) != -1) {
        unsigned long value = 0;
        switch (c) {
            case 'h':
                cfg->host = optarg;
                break;
            case 'p':
                if (!parse_uint(optarg, 65535, &value)) {
                    fprintf(stderr, "invalid port: %s\n", optarg);
                    return false;
                }
                cfg->port = static_cast<uint16_t>(value);
                break;
            case 's':
                if (!parse_uint(optarg, 0xffffffffUL, &value)) {
                    fprintf(stderr, "invalid ssrc: %s\n", optarg);
                    return false;
                }
                cfg->ssrc = static_cast<uint32_t>(value);
                break;
            case 'm':
                if (!parse_uint(optarg, 10, &value) || (value != 5 && value != 10)) {
                    fprintf(stderr, "packet-ms must be 5 or 10: %s\n", optarg);
                    return false;
                }
                cfg->packet_ms = static_cast<uint32_t>(value);
                break;
            case 'v':
                cfg->verbose = true;
                break;
            default:
                usage(argv[0]);
                return false;
        }
    }
    return true;
}

inline uint16_t swap16(uint16_t value) {
    return static_cast<uint16_t>((value << 8) | (value >> 8));
}

void put_u16(uint8_t* p, uint16_t value) {
    const uint16_t net = htons(value);
    memcpy(p, &net, sizeof(net));
}

void put_u32(uint8_t* p, uint32_t value) {
    const uint32_t net = htonl(value);
    memcpy(p, &net, sizeof(net));
}

double now_seconds() {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<double>(ts.tv_sec) + static_cast<double>(ts.tv_nsec) / 1e9;
}

bool capture_enabled() {
    return android::base::GetBoolProperty(kPropEnabled, true);
}

bool is_valid_ipv4(const std::string& host) {
    in_addr addr{};
    return inet_pton(AF_INET, host.c_str(), &addr) == 1;
}

void apply_runtime_config(Config* cfg) {
    if (cfg == nullptr) return;
    const std::string host = android::base::GetProperty(kPropHost, cfg->host);
    if (!host.empty() && is_valid_ipv4(host)) {
        cfg->host = host;
    }
    const int port = android::base::GetIntProperty(kPropPort, static_cast<int>(cfg->port));
    if (port > 0 && port <= 65535) {
        cfg->port = static_cast<uint16_t>(port);
    }
}

bool runtime_config_changed(const Config& cfg) {
    const std::string host = android::base::GetProperty(kPropHost, cfg.host);
    if (!host.empty() && is_valid_ipv4(host) && host != cfg.host) {
        return true;
    }
    const int port = android::base::GetIntProperty(kPropPort, static_cast<int>(cfg.port));
    if (port > 0 && port <= 65535 && static_cast<uint16_t>(port) != cfg.port) {
        return true;
    }
    return false;
}

void set_state(const char* state) {
    android::base::SetProperty(kPropState, state);
}

void set_stats(const char* stats) {
    android::base::SetProperty(kPropStats, stats);
}

int open_socket(const Config& cfg, sockaddr_in* destination) {
    const int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        ALOGE("socket(AF_INET, SOCK_DGRAM) failed: %s", strerror(errno));
        return -1;
    }

    int sndbuf = 1 << 20;
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

    memset(destination, 0, sizeof(*destination));
    destination->sin_family = AF_INET;
    destination->sin_port = htons(cfg.port);
    if (inet_pton(AF_INET, cfg.host.c_str(), &destination->sin_addr) != 1) {
        ALOGE("invalid IPv4 address: %s", cfg.host.c_str());
        close(fd);
        return -1;
    }
    return fd;
}

sp<AudioRecord> create_record(const Config& cfg) {
    size_t min_frames = 0;
    status_t status = AudioRecord::getMinFrameCount(
            &min_frames, kSampleRate, AUDIO_FORMAT_PCM_16_BIT, AUDIO_CHANNEL_IN_STEREO);
    if (status != android::NO_ERROR) {
        ALOGE("AudioRecord::getMinFrameCount failed: %d", status);
        return nullptr;
    }

    const size_t packet_frames = kSampleRate * cfg.packet_ms / 1000;
    size_t frame_count = packet_frames * 4;  // ~20 ms at 5 ms packets
    if (frame_count < min_frames) frame_count = min_frames;

    AttributionSourceState attribution;
    attribution.packageName = std::string("com.android.audio.rtp_sender");
    attribution.uid = static_cast<int32_t>(getuid());
    attribution.pid = static_cast<int32_t>(getpid());
    attribution.token = sp<BBinder>::make();

    sp<AudioRecord> record = new AudioRecord(
            AUDIO_SOURCE_REMOTE_SUBMIX,
            kSampleRate,
            AUDIO_FORMAT_PCM_16_BIT,
            AUDIO_CHANNEL_IN_STEREO,
            attribution,
            frame_count,
            nullptr,  // callback
            0,        // notificationFrames
            AUDIO_SESSION_ALLOCATE,
            AudioRecord::TRANSFER_DEFAULT,
            AUDIO_INPUT_FLAG_NONE,
            nullptr,  // attributes
            AUDIO_PORT_HANDLE_NONE);

    status = record->initCheck();
    if (status != android::NO_ERROR) {
        ALOGE("AudioRecord initCheck failed: %d", status);
        return nullptr;
    }
    record->setCallerName("audio-rtp-sender");
    ALOGI("capture ready: %u Hz, %u ch, buffer %zu frames (min %zu)",
          kSampleRate, kChannels, record->frameCount(), min_frames);
    return record;
}

bool run_sender(const Config& cfg) {
    sockaddr_in destination{};
    const int fd = open_socket(cfg, &destination);
    if (fd < 0) return false;

    sp<AudioRecord> record = create_record(cfg);
    if (record == nullptr) {
        close(fd);
        return false;
    }

    status_t status = record->start();
    if (status != android::NO_ERROR) {
        ALOGE("AudioRecord::start failed: %d", status);
        close(fd);
        return false;
    }

    const size_t packet_frames = kSampleRate * cfg.packet_ms / 1000;
    const size_t packet_bytes = packet_frames * kFrameBytes;
    uint8_t packet[12 + kMaxPacketFrames * kFrameBytes];
    uint8_t pcm[kMaxPacketFrames * kFrameBytes];
    memset(packet, 0, sizeof(packet));

    uint16_t sequence = static_cast<uint16_t>(now_seconds() * 1000.0);
    uint32_t timestamp = static_cast<uint32_t>(now_seconds() * kSampleRate);
    bool first_packet = true;

    uint64_t packets = 0;
    uint64_t frames = 0;
    uint64_t sent_bytes = 0;
    uint64_t send_errors = 0;
    double sum_squares = 0.0;
    double last_stats = now_seconds();

    ALOGI("sending RTP L16 to %s:%u (ssrc=%08x, %u ms/packet)",
          cfg.host.c_str(), cfg.port, cfg.ssrc, cfg.packet_ms);
    set_state("on");

    bool ok = true;
    while (!g_stop.load() && capture_enabled() && !runtime_config_changed(cfg)) {
        size_t filled = 0;
        while (filled < packet_bytes && !g_stop.load() && capture_enabled()) {
            const ssize_t n = record->read(pcm + filled, packet_bytes - filled, true);
            if (n < 0) {
                if (n == -EINTR && g_stop.load()) break;
                ALOGE("AudioRecord::read failed: %zd", n);
                ok = false;
                break;
            }
            if (n == 0) continue;
            size_t bytes = static_cast<size_t>(n);
            if (bytes % kFrameBytes != 0) {
                ALOGW("AudioRecord::read returned %zu bytes, not frame aligned", bytes);
                bytes -= bytes % kFrameBytes;
            }
            filled += bytes;
        }
        if (!ok) break;
        if (filled < packet_bytes) continue;

        // RTP fixed header.
        packet[0] = 0x80;  // V=2, P=0, X=0, CC=0
        packet[1] = static_cast<uint8_t>((first_packet ? 0x80 : 0x00) | kPayloadType);
        put_u16(packet + 2, sequence++);
        put_u32(packet + 4, timestamp);
        put_u32(packet + 8, cfg.ssrc);
        first_packet = false;

        // Android PCM is little-endian; RTP L16 is network byte order.
        const uint16_t* src = reinterpret_cast<const uint16_t*>(pcm);
        uint16_t* dst = reinterpret_cast<uint16_t*>(packet + 12);
        const size_t samples = packet_frames * kChannels;
        for (size_t i = 0; i < samples; ++i) {
            const uint16_t sample = src[i];
            dst[i] = swap16(sample);
            const int32_t s = static_cast<int16_t>(sample);
            sum_squares += static_cast<double>(s) * s;
        }
        timestamp += packet_frames;

        const ssize_t sent = sendto(fd, packet, 12 + packet_bytes, 0,
                                    reinterpret_cast<const sockaddr*>(&destination),
                                    sizeof(destination));
        if (sent < 0) {
            if (errno == EINTR && g_stop.load()) break;
            if (send_errors++ % 100 == 0) {
                ALOGW("sendto(%s:%u) failed: %s (total %" PRIu64 ")",
                      cfg.host.c_str(), cfg.port, strerror(errno), send_errors);
            }
        } else {
            packets++;
            frames += packet_frames;
            sent_bytes += static_cast<uint64_t>(sent);
        }

        const double now = now_seconds();
        if (now - last_stats >= 5.0) {
            const double elapsed = now - last_stats;
            const double pps = packets / elapsed;
            // RTP datagrams plus an estimate of the UDP/IP headers.  Ethernet
            // framing is not included (about +3% on the wire).
            const double kbps = (sent_bytes + 28.0 * packets) * 8.0 / elapsed / 1000.0;
            const double rms = frames > 0
                    ? sqrt(sum_squares / static_cast<double>(frames * kChannels))
                    : 0.0;
            ALOGI("stats: %" PRIu64 " packets, %.1f pps, %.0f kbps, rms=%.1f, errors=%" PRIu64,
                  packets, pps, kbps, rms, send_errors);
            char stats[96];
            snprintf(stats, sizeof(stats), "%.0fpps %.0fkbps rms=%.0f err=%" PRIu64,
                     pps, kbps, rms, send_errors);
            set_stats(stats);
            packets = 0;
            frames = 0;
            sent_bytes = 0;
            sum_squares = 0.0;
            send_errors = 0;
            last_stats = now;
        }
    }

    record->stop();
    record->stopAndJoinCallbacks();
    record.clear();
    close(fd);
    ALOGI("stopped");
    return ok;
}

}  // namespace

int main(int argc, char** argv) {
    Config cfg;
    if (!parse_args(argc, argv, &cfg)) {
        usage(argv[0]);
        return 2;
    }

    struct sigaction action {};
    action.sa_handler = handle_signal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    sigaction(SIGINT, &action, nullptr);
    sigaction(SIGTERM, &action, nullptr);

    ALOGI("starting audio-rtp-sender (uid=%u)", getuid());
    set_state("starting");
    while (!g_stop.load()) {
        if (!capture_enabled()) {
            set_state("off");
            usleep(250000);
            continue;
        }
        set_state("starting");
        Config session_cfg = cfg;
        apply_runtime_config(&session_cfg);
        if (!run_sender(session_cfg)) {
            set_state("error");
            if (!g_stop.load()) sleep(1);
        } else {
            set_state("off");
        }
    }
    set_state("off");
    ALOGI("stopped");
    return 0;
}
