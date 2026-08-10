#include "defcon_uart.h"

#include <expansion/expansion.h>
#include <furi.h>
#include <furi_hal.h>
#include <gui/elements.h>
#include <gui/gui.h>
#include <gui/modules/dialog_ex.h>
#include <gui/modules/submenu.h>
#include <gui/modules/text_box.h>
#include <gui/view.h>
#include <gui/view_dispatcher.h>
#include <notification/notification.h>
#include <notification/notification_messages.h>
#include <storage/storage.h>

#define DEFCON_VERSION        "1.0"
#define DEFCON_APP_DIR        EXT_PATH("apps_data/defcon_defense")
#define DEFCON_ALLOWLIST_PATH DEFCON_APP_DIR "/allowlist.txt"
#define DEFCON_EVIDENCE_PATH  DEFCON_APP_DIR "/evidence.log"
#define DEFCON_INCIDENT_PATH  DEFCON_APP_DIR "/incidents.log"
#define DEFCON_SETTINGS_PATH  DEFCON_APP_DIR "/settings.txt"

#define DEFCON_MAX_APS              (48)
#define DEFCON_MAX_CLIENTS          (32)
#define DEFCON_MAX_ALLOWLIST        (32)
#define DEFCON_MAX_INCIDENTS        (24)
#define DEFCON_SSID_SIZE            (33)
#define DEFCON_LINE_SIZE            (256)
#define DEFCON_TEXT_SIZE            (4096)
#define DEFCON_EVIDENCE_BUFFER_SIZE (2048)

#define DEFCON_AP_SCAN_MS      (8000)
#define DEFCON_CLIENT_SCAN_MS  (6000)
#define DEFCON_DEAUTH_WATCH_MS (7000)
#define DEFCON_PHASE_GAP_MS    (500)

typedef enum {
    DefconViewDashboard,
    DefconViewMenu,
    DefconViewList,
    DefconViewText,
    DefconViewDialog,
} DefconView;

typedef enum {
    DefconPhaseAp,
    DefconPhaseClient,
    DefconPhaseDeauth,
} DefconPhase;

typedef enum {
    DefconListNone,
    DefconListAddAllow,
    DefconListRemoveAllow,
} DefconListMode;

typedef enum {
    DefconEventOpenMenu = 100,
    DefconEventMenuBase = 200,
    DefconEventListBase = 300,
    DefconEventEmergencyConfirm = 400,
    DefconEventEmergencyCancel,
} DefconEvent;

typedef struct {
    char bssid[18];
    char ssid[DEFCON_SSID_SIZE];
    int8_t rssi;
    uint8_t channel;
    uint32_t generation;
    uint32_t last_seen_tick;
    uint32_t last_rssi_alert_tick;
    uint32_t last_twin_alert_tick;
    bool allowlisted;
} DefconAp;

typedef struct {
    char bssid[18];
    char ssid[DEFCON_SSID_SIZE];
} DefconAllowEntry;

typedef struct {
    char time[20];
    char type[18];
    char detail[64];
} DefconIncident;

typedef struct {
    uint8_t page;
    bool monitoring;
    bool emergency;
    bool phase_running;
    bool evidence_enabled;
    DefconPhase phase;
    uint8_t live_ap_count;
    uint8_t live_client_count;
    uint16_t deauth_count;
    uint16_t disassoc_count;
    uint16_t alert_total;
    uint8_t allow_count;
    uint8_t channel_counts[15];
    DefconAp aps[4];
    uint8_t display_ap_count;
    DefconIncident last_incident;
    bool has_incident;
} DefconDashboardModel;

typedef struct {
    Gui* gui;
    ViewDispatcher* dispatcher;
    View* dashboard;
    Submenu* menu;
    Submenu* list;
    TextBox* text_box;
    DialogEx* dialog;
    Storage* storage;
    NotificationApp* notification;
    DefconUart* uart;
    FuriMutex* state_mutex;

    FuriString* text;
    char evidence_buffer[DEFCON_EVIDENCE_BUFFER_SIZE];
    size_t evidence_buffer_length;
    uint32_t last_evidence_flush_tick;

    DefconView current_view;
    DefconListMode list_mode;
    uint8_t dashboard_page;
    bool monitoring;
    bool emergency;
    bool evidence_enabled;
    bool phase_running;
    DefconPhase phase;
    uint32_t phase_deadline;
    uint32_t scan_generation;

    DefconAp aps[DEFCON_MAX_APS];
    uint8_t ap_count;
    uint8_t live_ap_count;
    char clients[DEFCON_MAX_CLIENTS][18];
    uint8_t live_client_count;
    uint8_t channel_counts[15];
    DefconAllowEntry allowlist[DEFCON_MAX_ALLOWLIST];
    uint8_t allow_count;
    DefconIncident incidents[DEFCON_MAX_INCIDENTS];
    uint8_t incident_count;
    uint8_t incident_head;
    uint16_t alert_total;
    uint16_t deauth_count;
    uint16_t disassoc_count;
    uint32_t last_high_alert_tick;
    uint32_t last_management_incident_tick;

    char rx_line[DEFCON_LINE_SIZE];
    size_t rx_line_length;
} DefconApp;

typedef enum {
    DefconMenuRecon,
    DefconMenuApChannels,
    DefconMenuClients,
    DefconMenuIncidents,
    DefconMenuAllowAdd,
    DefconMenuAllowRemove,
    DefconMenuEvidenceView,
    DefconMenuEvidenceToggle,
    DefconMenuEmergency,
    DefconMenuStatus,
    DefconMenuExit,
    DefconMenuCount,
} DefconMenuItem;

static void defcon_refresh_dashboard(DefconApp* app);
static void defcon_start_monitoring(DefconApp* app);
static void defcon_stop_monitoring(DefconApp* app, bool power_down);
static void defcon_rebuild_menu(DefconApp* app);

static bool defcon_tick_elapsed(uint32_t now, uint32_t deadline) {
    return (int32_t)(now - deadline) >= 0;
}

static void defcon_format_time(char* buffer, size_t size) {
    DateTime dt;
    furi_hal_rtc_get_datetime(&dt);
    snprintf(
        buffer,
        size,
        "%04u-%02u-%02u %02u:%02u:%02u",
        (unsigned)(dt.year % 10000),
        (unsigned)(dt.month % 100),
        (unsigned)(dt.day % 100),
        (unsigned)(dt.hour % 100),
        (unsigned)(dt.minute % 100),
        (unsigned)(dt.second % 100));
}

static bool defcon_text_contains_ci(const char* text, const char* needle) {
    if(!text || !needle || !needle[0]) return false;
    const size_t needle_length = strlen(needle);
    for(const char* start = text; *start; ++start) {
        size_t i = 0;
        while(i < needle_length && start[i] &&
              tolower((unsigned char)start[i]) == tolower((unsigned char)needle[i])) {
            ++i;
        }
        if(i == needle_length) return true;
    }
    return false;
}

static void defcon_trim(char* text) {
    size_t length = strlen(text);
    while(length && isspace((unsigned char)text[length - 1]))
        text[--length] = '\0';
    size_t offset = 0;
    while(text[offset] && isspace((unsigned char)text[offset]))
        ++offset;
    if(offset) memmove(text, text + offset, strlen(text + offset) + 1);
}

static bool defcon_valid_mac(const char* text) {
    if(!text || strlen(text) < 17) return false;
    for(size_t i = 0; i < 17; ++i) {
        if((i + 1) % 3 == 0) {
            if(text[i] != ':') return false;
        } else if(!isxdigit((unsigned char)text[i])) {
            return false;
        }
    }
    return true;
}

static bool defcon_find_mac(const char* text, char output[18]) {
    for(const char* cursor = text; cursor && *cursor; ++cursor) {
        if(defcon_valid_mac(cursor)) {
            memcpy(output, cursor, 17);
            output[17] = '\0';
            for(size_t i = 0; i < 17; ++i)
                output[i] = tolower((unsigned char)output[i]);
            return true;
        }
    }
    return false;
}

static size_t
    defcon_format_log_line(char* output, size_t output_size, const char* type, const char* detail) {
    char timestamp[20];
    defcon_format_time(timestamp, sizeof(timestamp));
    const int length = snprintf(output, output_size, "%s|%s|%s\n", timestamp, type, detail);
    return length > 0 ? MIN((size_t)length, output_size - 1) : 0;
}

static void
    defcon_append_bytes(DefconApp* app, const char* path, const void* data, size_t length) {
    if(!length) return;
    File* file = storage_file_alloc(app->storage);
    if(storage_file_open(file, path, FSAM_WRITE, FSOM_OPEN_ALWAYS)) {
        storage_file_seek(file, (uint32_t)storage_file_size(file), true);
        storage_file_write(file, data, length);
        storage_file_sync(file);
        storage_file_close(file);
    }
    storage_file_free(file);
}

static void defcon_flush_evidence_locked(DefconApp* app) {
    if(!app->evidence_buffer_length) return;
    defcon_append_bytes(
        app, DEFCON_EVIDENCE_PATH, app->evidence_buffer, app->evidence_buffer_length);
    app->evidence_buffer_length = 0;
}

static void defcon_queue_evidence_locked(DefconApp* app, const char* type, const char* detail) {
    char line[384];
    const size_t length = defcon_format_log_line(line, sizeof(line), type, detail);
    if(!length) return;
    if(app->evidence_buffer_length + length > sizeof(app->evidence_buffer)) {
        defcon_flush_evidence_locked(app);
    }
    memcpy(app->evidence_buffer + app->evidence_buffer_length, line, length);
    app->evidence_buffer_length += length;
}

static void defcon_append_incident_locked(DefconApp* app, const char* type, const char* detail) {
    char line[160];
    const size_t length = defcon_format_log_line(line, sizeof(line), type, detail);
    defcon_append_bytes(app, DEFCON_INCIDENT_PATH, line, length);
}

static void defcon_log_ui(DefconApp* app, const char* detail) {
    furi_mutex_acquire(app->state_mutex, FuriWaitForever);
    if(app->evidence_enabled) {
        defcon_queue_evidence_locked(app, "UI", detail);
        defcon_flush_evidence_locked(app);
    }
    furi_mutex_release(app->state_mutex);
}

static bool defcon_is_allowlisted_locked(DefconApp* app, const char* bssid) {
    for(uint8_t i = 0; i < app->allow_count; ++i) {
        if(strcmp(app->allowlist[i].bssid, bssid) == 0) return true;
    }
    return false;
}

static bool
    defcon_is_trusted_ssid_other_bssid_locked(DefconApp* app, const char* ssid, const char* bssid) {
    if(!ssid[0]) return false;
    for(uint8_t i = 0; i < app->allow_count; ++i) {
        if(strcmp(app->allowlist[i].ssid, ssid) == 0 &&
           strcmp(app->allowlist[i].bssid, bssid) != 0) {
            return true;
        }
    }
    return false;
}

static void defcon_notify_alert_locked(DefconApp* app, bool high_priority) {
    const uint32_t now = furi_get_tick();
    if(high_priority &&
       (!app->last_high_alert_tick ||
        defcon_tick_elapsed(now, app->last_high_alert_tick + furi_ms_to_ticks(3000)))) {
        notification_message(app->notification, &sequence_blink_red_100);
        notification_message(app->notification, &sequence_single_vibro);
        app->last_high_alert_tick = now;
    } else if(!high_priority) {
        notification_message(app->notification, &sequence_blink_yellow_10);
    }
}

static void defcon_add_incident_locked(
    DefconApp* app,
    const char* type,
    const char* detail,
    bool high_priority) {
    DefconIncident* incident = &app->incidents[app->incident_head];
    memset(incident, 0, sizeof(DefconIncident));
    defcon_format_time(incident->time, sizeof(incident->time));
    snprintf(incident->type, sizeof(incident->type), "%s", type);
    snprintf(incident->detail, sizeof(incident->detail), "%s", detail);

    app->incident_head = (app->incident_head + 1) % DEFCON_MAX_INCIDENTS;
    if(app->incident_count < DEFCON_MAX_INCIDENTS) ++app->incident_count;
    ++app->alert_total;
    defcon_append_incident_locked(app, type, detail);
    if(app->evidence_enabled) defcon_queue_evidence_locked(app, type, detail);
    defcon_notify_alert_locked(app, high_priority);
}

static DefconAp* defcon_find_ap_locked(DefconApp* app, const char* bssid) {
    for(uint8_t i = 0; i < app->ap_count; ++i) {
        if(strcmp(app->aps[i].bssid, bssid) == 0) return &app->aps[i];
    }
    return NULL;
}

static DefconAp* defcon_alloc_ap_locked(DefconApp* app) {
    if(app->ap_count < DEFCON_MAX_APS) return &app->aps[app->ap_count++];

    DefconAp* oldest = &app->aps[0];
    for(uint8_t i = 1; i < app->ap_count; ++i) {
        if(app->aps[i].last_seen_tick < oldest->last_seen_tick) oldest = &app->aps[i];
    }
    return oldest;
}

static bool defcon_parse_ap_line(
    const char* line,
    int* rssi,
    int* channel,
    char bssid[18],
    char ssid[DEFCON_SSID_SIZE]) {
    const char* rssi_at = strstr(line, "RSSI:");
    const char* channel_at = strstr(line, "Ch:");
    const char* bssid_at = strstr(line, "BSSID:");
    const char* ssid_at = strstr(line, "ESSID:");
    if(!rssi_at || !channel_at || !bssid_at || !ssid_at) return false;
    if(sscanf(rssi_at, "RSSI: %d", rssi) != 1 || sscanf(channel_at, "Ch: %d", channel) != 1) {
        return false;
    }

    bssid_at += strlen("BSSID:");
    while(*bssid_at == ' ')
        ++bssid_at;
    if(!defcon_valid_mac(bssid_at)) return false;
    memcpy(bssid, bssid_at, 17);
    bssid[17] = '\0';
    for(size_t i = 0; i < 17; ++i)
        bssid[i] = tolower((unsigned char)bssid[i]);

    ssid_at += strlen("ESSID:");
    while(*ssid_at == ' ')
        ++ssid_at;
    snprintf(ssid, DEFCON_SSID_SIZE, "%s", ssid_at);
    defcon_trim(ssid);
    if(strcmp(ssid, bssid) == 0) ssid[0] = '\0';
    return true;
}

static void defcon_process_ap_locked(DefconApp* app, const char* line) {
    int rssi = 0;
    int channel = 0;
    char bssid[18];
    char ssid[DEFCON_SSID_SIZE];
    if(!defcon_parse_ap_line(line, &rssi, &channel, bssid, ssid)) return;

    const uint32_t now = furi_get_tick();
    DefconAp* ap = defcon_find_ap_locked(app, bssid);
    const bool is_new = !ap;
    if(is_new) {
        ap = defcon_alloc_ap_locked(app);
        memset(ap, 0, sizeof(DefconAp));
        snprintf(ap->bssid, sizeof(ap->bssid), "%s", bssid);
    }

    const uint8_t previous_channel = ap->channel;
    const int8_t previous_rssi = ap->rssi;
    if(ap->generation != app->scan_generation) {
        ap->generation = app->scan_generation;
        ++app->live_ap_count;
        if(channel > 0 && channel < 15) ++app->channel_counts[channel];
    }

    snprintf(ap->ssid, sizeof(ap->ssid), "%s", ssid);
    ap->rssi = CLAMP(rssi, -127, 0);
    ap->channel = CLAMP(channel, 0, 255);
    ap->last_seen_tick = now;
    ap->allowlisted = defcon_is_allowlisted_locked(app, bssid);

    char detail[64];
    const char* display_ssid = ssid[0] ? ssid : "<hidden>";
    if(is_new && !ap->allowlisted) {
        snprintf(detail, sizeof(detail), "%.17s %.30s", bssid, display_ssid);
        defcon_add_incident_locked(app, "NEW BSSID", detail, false);
    }

    if(!ap->allowlisted && defcon_is_trusted_ssid_other_bssid_locked(app, ssid, bssid) &&
       (!ap->last_twin_alert_tick ||
        defcon_tick_elapsed(now, ap->last_twin_alert_tick + furi_ms_to_ticks(60000)))) {
        snprintf(detail, sizeof(detail), "%.28s via %.17s", display_ssid, bssid);
        defcon_add_incident_locked(app, "POSSIBLE TWIN", detail, true);
        ap->last_twin_alert_tick = now;
    }

    if(!is_new && previous_channel && previous_channel != ap->channel) {
        snprintf(detail, sizeof(detail), "%.17s ch%u>%u", bssid, previous_channel, ap->channel);
        defcon_add_incident_locked(app, "CHANNEL CHANGE", detail, false);
    }

    if(!is_new && previous_rssi && abs(previous_rssi - ap->rssi) >= 20 &&
       (!ap->last_rssi_alert_tick ||
        defcon_tick_elapsed(now, ap->last_rssi_alert_tick + furi_ms_to_ticks(15000)))) {
        snprintf(detail, sizeof(detail), "%.17s %ddBm>%ddBm", bssid, previous_rssi, ap->rssi);
        defcon_add_incident_locked(app, "RSSI SHIFT", detail, false);
        ap->last_rssi_alert_tick = now;
    }
}

static void defcon_process_client_locked(DefconApp* app, const char* line) {
    if(!(defcon_text_contains_ci(line, "station") || defcon_text_contains_ci(line, "client") ||
         defcon_text_contains_ci(line, " sta "))) {
        return;
    }
    if(line[0] == '#' || defcon_text_contains_ci(line, "starting") ||
       defcon_text_contains_ci(line, "stopping")) {
        return;
    }

    char mac[18];
    if(!defcon_find_mac(line, mac)) return;
    for(uint8_t i = 0; i < app->live_client_count; ++i) {
        if(strcmp(app->clients[i], mac) == 0) return;
    }
    if(app->live_client_count < DEFCON_MAX_CLIENTS) {
        snprintf(app->clients[app->live_client_count++], 18, "%s", mac);
    }
}

static void defcon_process_management_anomaly_locked(DefconApp* app, const char* line) {
    if(line[0] == '#' || defcon_text_contains_ci(line, "starting") ||
       defcon_text_contains_ci(line, "stopping") || defcon_text_contains_ci(line, "stopscan")) {
        return;
    }

    const bool disassoc = defcon_text_contains_ci(line, "disassoc");
    const bool deauth = defcon_text_contains_ci(line, "deauth");
    if(!disassoc && !deauth) return;

    char mac[18] = "unknown source";
    defcon_find_mac(line, mac);
    if(disassoc) {
        ++app->disassoc_count;
    } else {
        ++app->deauth_count;
    }

    const uint32_t now = furi_get_tick();
    if(!app->last_management_incident_tick ||
       defcon_tick_elapsed(now, app->last_management_incident_tick + furi_ms_to_ticks(2000))) {
        defcon_add_incident_locked(app, disassoc ? "DISASSOC FRAME" : "DEAUTH FRAME", mac, true);
        app->last_management_incident_tick = now;
    }
}

static void defcon_process_line(DefconApp* app, const char* line) {
    if(!line[0]) return;
    furi_mutex_acquire(app->state_mutex, FuriWaitForever);

    if(app->evidence_enabled && line[0] != '>') {
        defcon_queue_evidence_locked(app, "OBS", line);
    }
    defcon_process_ap_locked(app, line);
    if(app->phase == DefconPhaseClient) defcon_process_client_locked(app, line);
    if(app->phase == DefconPhaseDeauth) defcon_process_management_anomaly_locked(app, line);

    furi_mutex_release(app->state_mutex);
}

static void defcon_uart_rx(const uint8_t* data, size_t length, void* context) {
    DefconApp* app = context;
    for(size_t i = 0; i < length; ++i) {
        const char c = data[i];
        if(c == '\n' || c == '\r') {
            if(app->rx_line_length) {
                app->rx_line[app->rx_line_length] = '\0';
                defcon_process_line(app, app->rx_line);
                app->rx_line_length = 0;
            }
        } else if(app->rx_line_length < sizeof(app->rx_line) - 1) {
            app->rx_line[app->rx_line_length++] = c;
        } else {
            app->rx_line_length = 0;
        }
    }
}

static void defcon_send_stop(DefconApp* app, bool power_down) {
    defcon_uart_tx(app->uart, "stopscan\n");
    if(power_down) defcon_uart_tx(app->uart, "stopscan -f\n");
}

static uint32_t defcon_phase_duration(DefconPhase phase) {
    if(phase == DefconPhaseAp) return DEFCON_AP_SCAN_MS;
    if(phase == DefconPhaseClient) return DEFCON_CLIENT_SCAN_MS;
    return DEFCON_DEAUTH_WATCH_MS;
}

static void defcon_start_phase(DefconApp* app) {
    furi_mutex_acquire(app->state_mutex, FuriWaitForever);
    if(!app->monitoring || app->emergency) {
        furi_mutex_release(app->state_mutex);
        return;
    }

    if(app->phase == DefconPhaseAp) {
        ++app->scan_generation;
        app->live_ap_count = 0;
        memset(app->channel_counts, 0, sizeof(app->channel_counts));
        defcon_uart_tx(app->uart, "scanap\n");
    } else if(app->phase == DefconPhaseClient) {
        app->live_client_count = 0;
        memset(app->clients, 0, sizeof(app->clients));
        defcon_uart_tx(app->uart, "scansta\n");
    } else {
        defcon_uart_tx(app->uart, "sniffdeauth\n");
    }

    app->phase_running = true;
    app->phase_deadline = furi_get_tick() + furi_ms_to_ticks(defcon_phase_duration(app->phase));
    furi_mutex_release(app->state_mutex);
}

static void defcon_start_monitoring(DefconApp* app) {
    furi_mutex_acquire(app->state_mutex, FuriWaitForever);
    app->emergency = false;
    app->monitoring = true;
    app->phase = DefconPhaseAp;
    app->phase_running = false;
    furi_mutex_release(app->state_mutex);
    defcon_send_stop(app, false);
    defcon_start_phase(app);
}

static void defcon_stop_monitoring(DefconApp* app, bool power_down) {
    furi_mutex_acquire(app->state_mutex, FuriWaitForever);
    app->monitoring = false;
    app->phase_running = false;
    if(power_down) app->emergency = true;
    furi_mutex_release(app->state_mutex);
    defcon_send_stop(app, power_down);
}

static void defcon_dashboard_draw(Canvas* canvas, void* model_context) {
    DefconDashboardModel* model = model_context;
    canvas_clear(canvas);
    canvas_set_color(canvas, ColorBlack);
    canvas_draw_box(canvas, 0, 0, 128, 12);
    canvas_set_color(canvas, ColorWhite);
    canvas_set_font(canvas, FontPrimary);
    canvas_draw_str(canvas, 3, 10, model->emergency ? "RECON!" : "RECON");
    canvas_set_font(canvas, FontSecondary);
    canvas_draw_str(canvas, 92, 9, "2.4G");
    canvas_set_color(canvas, ColorBlack);

    char line[64];
    if(model->emergency) {
        canvas_set_font(canvas, FontPrimary);
        canvas_draw_str(canvas, 6, 27, "EMERGENCY MODE");
        canvas_set_font(canvas, FontSecondary);
        canvas_draw_str(canvas, 6, 39, "ESP Wi-Fi stopped");
        canvas_draw_str(canvas, 6, 49, "Use wired/trusted link");
        canvas_draw_str(canvas, 6, 61, "OK: response menu");
        return;
    }

    if(model->page == 0) {
        canvas_set_font(canvas, FontPrimary);
        snprintf(
            line,
            sizeof(line),
            "AP:%u  CLI:%u  !:%u",
            model->live_ap_count,
            model->live_client_count,
            model->alert_total);
        canvas_draw_str(canvas, 3, 26, line);
        canvas_set_font(canvas, FontSecondary);
        const char* phase = model->phase == DefconPhaseAp     ? "AP observation" :
                            model->phase == DefconPhaseClient ? "Client observation" :
                                                                "Deauth watch";
        snprintf(line, sizeof(line), "%s: %s", model->monitoring ? "LIVE" : "PAUSED", phase);
        canvas_draw_str(canvas, 3, 39, line);
        snprintf(
            line,
            sizeof(line),
            "Deauth:%u Disassoc:%u",
            model->deauth_count,
            model->disassoc_count);
        canvas_draw_str(canvas, 3, 50, line);
        snprintf(line, sizeof(line), "Allow:%u  5G:N/A on S2", model->allow_count);
        canvas_draw_str(canvas, 3, 61, line);
    } else if(model->page == 1) {
        canvas_set_font(canvas, FontSecondary);
        canvas_draw_str(canvas, 3, 22, "LATEST ACCESS POINTS");
        for(uint8_t i = 0; i < model->display_ap_count && i < 3; ++i) {
            const DefconAp* ap = &model->aps[i];
            snprintf(
                line,
                sizeof(line),
                "%c%-15.15s %d/%u",
                ap->allowlisted ? '+' : '!',
                ap->ssid[0] ? ap->ssid : ap->bssid,
                ap->rssi,
                ap->channel);
            canvas_draw_str(canvas, 3, 34 + (i * 11), line);
        }
    } else if(model->page == 2) {
        canvas_set_font(canvas, FontSecondary);
        canvas_draw_str(canvas, 3, 22, "CHANNEL ACTIVITY");
        uint8_t y = 34;
        for(uint8_t channel = 1; channel <= 13; ++channel) {
            if(!model->channel_counts[channel]) continue;
            snprintf(line, sizeof(line), "ch%-2u ", channel);
            canvas_draw_str(canvas, 3, y, line);
            const uint8_t width = MIN(model->channel_counts[channel] * 6, 86);
            canvas_draw_box(canvas, 33, y - 7, width, 6);
            y += 10;
            if(y > 62) break;
        }
        if(y == 34) canvas_draw_str(canvas, 3, 36, "Waiting for AP sweep...");
    } else {
        canvas_set_font(canvas, FontSecondary);
        canvas_draw_str(canvas, 3, 22, "LATEST INCIDENT");
        if(model->has_incident) {
            canvas_draw_str(canvas, 3, 34, model->last_incident.type);
            snprintf(line, sizeof(line), "%.20s", model->last_incident.detail);
            canvas_draw_str(canvas, 3, 45, line);
            canvas_draw_str(canvas, 3, 56, model->last_incident.time + 11);
        } else {
            canvas_draw_str(canvas, 3, 36, "No incidents this run");
        }
    }

    canvas_set_font(canvas, FontSecondary);
    elements_button_center(canvas, "Menu");
}

static bool defcon_dashboard_input(InputEvent* event, void* context) {
    DefconApp* app = context;
    if(event->type != InputTypeShort && event->type != InputTypeRepeat) return false;
    if(event->key == InputKeyOk) {
        view_dispatcher_send_custom_event(app->dispatcher, DefconEventOpenMenu);
        return true;
    }
    if(event->key == InputKeyLeft) {
        app->dashboard_page = app->dashboard_page ? app->dashboard_page - 1 : 3;
        defcon_refresh_dashboard(app);
        return true;
    }
    if(event->key == InputKeyRight) {
        app->dashboard_page = (app->dashboard_page + 1) % 4;
        defcon_refresh_dashboard(app);
        return true;
    }
    return false;
}

static void defcon_switch_view(DefconApp* app, DefconView view) {
    app->current_view = view;
    view_dispatcher_switch_to_view(app->dispatcher, view);
}

static void defcon_refresh_dashboard(DefconApp* app) {
    furi_mutex_acquire(app->state_mutex, FuriWaitForever);
    with_view_model(
        app->dashboard,
        DefconDashboardModel * model,
        {
            memset(model, 0, sizeof(DefconDashboardModel));
            model->page = app->dashboard_page;
            model->monitoring = app->monitoring;
            model->emergency = app->emergency;
            model->phase_running = app->phase_running;
            model->evidence_enabled = app->evidence_enabled;
            model->phase = app->phase;
            model->live_ap_count = app->live_ap_count;
            model->live_client_count = app->live_client_count;
            model->deauth_count = app->deauth_count;
            model->disassoc_count = app->disassoc_count;
            model->alert_total = app->alert_total;
            model->allow_count = app->allow_count;
            memcpy(model->channel_counts, app->channel_counts, sizeof(model->channel_counts));

            for(uint8_t i = 0; i < app->ap_count && model->display_ap_count < 4; ++i) {
                const DefconAp* candidate = &app->aps[app->ap_count - 1 - i];
                if(candidate->generation == app->scan_generation) {
                    model->aps[model->display_ap_count++] = *candidate;
                }
            }

            if(app->incident_count) {
                const uint8_t newest =
                    (app->incident_head + DEFCON_MAX_INCIDENTS - 1) % DEFCON_MAX_INCIDENTS;
                model->last_incident = app->incidents[newest];
                model->has_incident = true;
            }
        },
        true);
    furi_mutex_release(app->state_mutex);
}

static void defcon_menu_callback(void* context, uint32_t index) {
    DefconApp* app = context;
    view_dispatcher_send_custom_event(app->dispatcher, DefconEventMenuBase + index);
}

static void defcon_list_callback(void* context, uint32_t index) {
    DefconApp* app = context;
    view_dispatcher_send_custom_event(app->dispatcher, DefconEventListBase + index);
}

static void defcon_dialog_callback(DialogExResult result, void* context) {
    DefconApp* app = context;
    view_dispatcher_send_custom_event(
        app->dispatcher,
        result == DialogExResultRight ? DefconEventEmergencyConfirm : DefconEventEmergencyCancel);
}

static void defcon_save_settings(DefconApp* app) {
    File* file = storage_file_alloc(app->storage);
    if(storage_file_open(file, DEFCON_SETTINGS_PATH, FSAM_WRITE, FSOM_CREATE_ALWAYS)) {
        const char* value = app->evidence_enabled ? "evidence=1\n" : "evidence=0\n";
        storage_file_write(file, value, strlen(value));
        storage_file_close(file);
    }
    storage_file_free(file);
}

static void defcon_load_settings(DefconApp* app) {
    app->evidence_enabled = true;
    File* file = storage_file_alloc(app->storage);
    if(storage_file_open(file, DEFCON_SETTINGS_PATH, FSAM_READ, FSOM_OPEN_EXISTING)) {
        char value[24] = {0};
        storage_file_read(file, value, sizeof(value) - 1);
        if(strstr(value, "evidence=0")) app->evidence_enabled = false;
        storage_file_close(file);
    }
    storage_file_free(file);
}

static void defcon_save_allowlist(DefconApp* app) {
    File* file = storage_file_alloc(app->storage);
    if(storage_file_open(file, DEFCON_ALLOWLIST_PATH, FSAM_WRITE, FSOM_CREATE_ALWAYS)) {
        char line[80];
        for(uint8_t i = 0; i < app->allow_count; ++i) {
            const int length = snprintf(
                line, sizeof(line), "%s|%s\n", app->allowlist[i].bssid, app->allowlist[i].ssid);
            if(length > 0) storage_file_write(file, line, MIN((size_t)length, sizeof(line) - 1));
        }
        storage_file_close(file);
    }
    storage_file_free(file);
}

static void defcon_load_allowlist(DefconApp* app) {
    File* file = storage_file_alloc(app->storage);
    if(storage_file_open(file, DEFCON_ALLOWLIST_PATH, FSAM_READ, FSOM_OPEN_EXISTING)) {
        const uint64_t file_size = storage_file_size(file);
        const size_t read_size = MIN(file_size, (uint64_t)2047);
        char* buffer = malloc(read_size + 1);
        memset(buffer, 0, read_size + 1);
        storage_file_read(file, buffer, read_size);

        char* cursor = buffer;
        while(*cursor && app->allow_count < DEFCON_MAX_ALLOWLIST) {
            char* line = cursor;
            while(*cursor && *cursor != '\r' && *cursor != '\n')
                ++cursor;
            if(*cursor) {
                *cursor++ = '\0';
                while(*cursor == '\r' || *cursor == '\n')
                    ++cursor;
            }

            char* separator = strchr(line, '|');
            if(separator) {
                *separator = '\0';
                if(defcon_valid_mac(line)) {
                    DefconAllowEntry* entry = &app->allowlist[app->allow_count++];
                    snprintf(entry->bssid, sizeof(entry->bssid), "%.17s", line);
                    snprintf(entry->ssid, sizeof(entry->ssid), "%s", separator + 1);
                }
            }
        }
        free(buffer);
        storage_file_close(file);
    }
    storage_file_free(file);
}

static void defcon_show_text(DefconApp* app, const char* text) {
    furi_string_set(app->text, text);
    text_box_reset(app->text_box);
    text_box_set_font(app->text_box, TextBoxFontText);
    text_box_set_focus(app->text_box, TextBoxFocusStart);
    text_box_set_text(app->text_box, furi_string_get_cstr(app->text));
    defcon_switch_view(app, DefconViewText);
}

static void defcon_show_incidents(DefconApp* app) {
    furi_string_set(app->text, "INCIDENTS (newest first)\n\n");
    furi_mutex_acquire(app->state_mutex, FuriWaitForever);
    if(!app->incident_count) {
        furi_string_cat_str(app->text, "No incidents this run.\n");
    } else {
        for(uint8_t offset = 0; offset < app->incident_count; ++offset) {
            const uint8_t index =
                (app->incident_head + DEFCON_MAX_INCIDENTS - 1 - offset) % DEFCON_MAX_INCIDENTS;
            const DefconIncident* incident = &app->incidents[index];
            furi_string_cat_printf(
                app->text, "%s\n%s\n%s\n\n", incident->time, incident->type, incident->detail);
        }
    }
    furi_mutex_release(app->state_mutex);
    text_box_reset(app->text_box);
    text_box_set_font(app->text_box, TextBoxFontText);
    text_box_set_focus(app->text_box, TextBoxFocusStart);
    text_box_set_text(app->text_box, furi_string_get_cstr(app->text));
    defcon_switch_view(app, DefconViewText);
}

static void defcon_show_evidence(DefconApp* app) {
    furi_string_set(app->text, "EVIDENCE LOG (tail)\n\n");
    File* file = storage_file_alloc(app->storage);
    furi_mutex_acquire(app->state_mutex, FuriWaitForever);
    defcon_flush_evidence_locked(app);
    if(storage_file_open(file, DEFCON_EVIDENCE_PATH, FSAM_READ, FSOM_OPEN_EXISTING)) {
        const uint64_t size = storage_file_size(file);
        const size_t amount = MIN(size, (uint64_t)(DEFCON_TEXT_SIZE - 128));
        if(size > amount) storage_file_seek(file, size - amount, true);
        char* buffer = malloc(amount + 1);
        memset(buffer, 0, amount + 1);
        storage_file_read(file, buffer, amount);
        furi_string_cat_str(app->text, buffer);
        free(buffer);
        storage_file_close(file);
    } else {
        furi_string_cat_str(app->text, "No evidence recorded yet.\n");
    }
    storage_file_free(file);
    furi_mutex_release(app->state_mutex);
    text_box_reset(app->text_box);
    text_box_set_font(app->text_box, TextBoxFontText);
    text_box_set_focus(app->text_box, TextBoxFocusEnd);
    text_box_set_text(app->text_box, furi_string_get_cstr(app->text));
    defcon_switch_view(app, DefconViewText);
}

static void defcon_open_allowlist(DefconApp* app, bool add) {
    submenu_reset(app->list);
    app->list_mode = add ? DefconListAddAllow : DefconListRemoveAllow;
    submenu_set_header(app->list, add ? "Allow current AP" : "Remove allowlist");

    furi_mutex_acquire(app->state_mutex, FuriWaitForever);
    if(add) {
        for(uint8_t i = 0; i < app->ap_count; ++i) {
            const DefconAp* ap = &app->aps[i];
            if(defcon_is_allowlisted_locked(app, ap->bssid)) continue;
            char label[40];
            snprintf(
                label, sizeof(label), "%.20s %.8s", ap->ssid[0] ? ap->ssid : "<hidden>", ap->bssid);
            submenu_add_item(app->list, label, i, defcon_list_callback, app);
        }
    } else {
        for(uint8_t i = 0; i < app->allow_count; ++i) {
            char label[40];
            snprintf(
                label,
                sizeof(label),
                "%.20s %.8s",
                app->allowlist[i].ssid[0] ? app->allowlist[i].ssid : "<hidden>",
                app->allowlist[i].bssid);
            submenu_add_item(app->list, label, i, defcon_list_callback, app);
        }
    }
    furi_mutex_release(app->state_mutex);
    defcon_switch_view(app, DefconViewList);
}

static void defcon_rebuild_menu(DefconApp* app) {
    submenu_reset(app->menu);
    submenu_set_header(app->menu, "DEFCON Defense");
    submenu_add_item(app->menu, "RECON Monitor", DefconMenuRecon, defcon_menu_callback, app);
    submenu_add_item(app->menu, "AP & Channels", DefconMenuApChannels, defcon_menu_callback, app);
    submenu_add_item(app->menu, "Client Activity", DefconMenuClients, defcon_menu_callback, app);
    submenu_add_item(app->menu, "Incident View", DefconMenuIncidents, defcon_menu_callback, app);
    submenu_add_item(
        app->menu, "Allowlist: Add AP", DefconMenuAllowAdd, defcon_menu_callback, app);
    submenu_add_item(
        app->menu, "Allowlist: Remove", DefconMenuAllowRemove, defcon_menu_callback, app);
    submenu_add_item(
        app->menu, "Evidence: View", DefconMenuEvidenceView, defcon_menu_callback, app);
    submenu_add_item(
        app->menu,
        app->evidence_enabled ? "Evidence logging: ON" : "Evidence logging: OFF",
        DefconMenuEvidenceToggle,
        defcon_menu_callback,
        app);
    submenu_add_item(
        app->menu,
        app->emergency ? "Emergency: ACTIVE" : "Emergency Mode",
        DefconMenuEmergency,
        defcon_menu_callback,
        app);
    submenu_add_item(app->menu, "Device Status", DefconMenuStatus, defcon_menu_callback, app);
    submenu_add_item(app->menu, "Exit application", DefconMenuExit, defcon_menu_callback, app);
}

static void defcon_handle_menu(DefconApp* app, uint32_t index) {
    switch(index) {
    case DefconMenuRecon:
        defcon_log_ui(app, "RECON summary opened");
        app->dashboard_page = 0;
        defcon_refresh_dashboard(app);
        defcon_switch_view(app, DefconViewDashboard);
        break;
    case DefconMenuApChannels:
        defcon_log_ui(app, "AP and channel page opened");
        app->dashboard_page = 1;
        defcon_refresh_dashboard(app);
        defcon_switch_view(app, DefconViewDashboard);
        break;
    case DefconMenuClients:
        defcon_log_ui(app, "client activity page opened");
        app->dashboard_page = 3;
        defcon_refresh_dashboard(app);
        defcon_switch_view(app, DefconViewDashboard);
        break;
    case DefconMenuIncidents:
        defcon_log_ui(app, "incident view opened");
        defcon_show_incidents(app);
        break;
    case DefconMenuAllowAdd:
        defcon_log_ui(app, "allowlist add opened");
        defcon_open_allowlist(app, true);
        break;
    case DefconMenuAllowRemove:
        defcon_log_ui(app, "allowlist remove opened");
        defcon_open_allowlist(app, false);
        break;
    case DefconMenuEvidenceView:
        defcon_log_ui(app, "evidence view opened");
        defcon_show_evidence(app);
        break;
    case DefconMenuEvidenceToggle:
        furi_mutex_acquire(app->state_mutex, FuriWaitForever);
        app->evidence_enabled = !app->evidence_enabled;
        furi_mutex_release(app->state_mutex);
        defcon_save_settings(app);
        defcon_rebuild_menu(app);
        defcon_switch_view(app, DefconViewMenu);
        break;
    case DefconMenuEmergency:
        defcon_log_ui(app, "emergency dialog opened");
        dialog_ex_reset(app->dialog);
        dialog_ex_set_header(
            app->dialog,
            app->emergency ? "Resume RECON?" : "Emergency mode?",
            64,
            10,
            AlignCenter,
            AlignCenter);
        dialog_ex_set_text(
            app->dialog,
            app->emergency ? "Restart passive\nobservation only" :
                             "Stop ESP Wi-Fi\nand all local scans",
            64,
            31,
            AlignCenter,
            AlignCenter);
        dialog_ex_set_left_button_text(app->dialog, "Cancel");
        dialog_ex_set_right_button_text(app->dialog, app->emergency ? "Resume" : "ENABLE");
        dialog_ex_set_result_callback(app->dialog, defcon_dialog_callback);
        dialog_ex_set_context(app->dialog, app);
        defcon_switch_view(app, DefconViewDialog);
        break;
    case DefconMenuStatus:
        defcon_show_text(
            app,
            "DEFCON DEFENSE v" DEFCON_VERSION "\n\n"
            "Target: AIO V1.4 / ESP32-S2\n"
            "Flipper API: 87.1\n\n"
            "2.4 GHz: passive observation\n"
            "5 GHz: unavailable on ESP32-S2\n\n"
            "Commands: scanap, scansta,\n"
            "sniffdeauth, stopscan only.\n"
            "No attack/injection features.\n\n"
            "Evidence:\n/ext/apps_data/\n"
            "defcon_defense/evidence.log\n\n"
            "OK opens the in-app menu.\n"
            "LEFT/RIGHT changes RECON page.\n");
        break;
    case DefconMenuExit:
        view_dispatcher_stop(app->dispatcher);
        break;
    default:
        break;
    }
}

static void defcon_handle_list(DefconApp* app, uint32_t index) {
    furi_mutex_acquire(app->state_mutex, FuriWaitForever);
    if(app->list_mode == DefconListAddAllow && index < app->ap_count &&
       app->allow_count < DEFCON_MAX_ALLOWLIST &&
       !defcon_is_allowlisted_locked(app, app->aps[index].bssid)) {
        DefconAllowEntry new_entry = {0};
        memcpy(new_entry.bssid, app->aps[index].bssid, sizeof(new_entry.bssid));
        memcpy(new_entry.ssid, app->aps[index].ssid, sizeof(new_entry.ssid));
        app->allowlist[app->allow_count++] = new_entry;
        app->aps[index].allowlisted = true;
        defcon_add_incident_locked(app, "ALLOWLIST ADD", new_entry.bssid, false);
    } else if(app->list_mode == DefconListRemoveAllow && index < app->allow_count) {
        char removed[18];
        snprintf(removed, sizeof(removed), "%s", app->allowlist[index].bssid);
        for(uint8_t i = index; i + 1 < app->allow_count; ++i) {
            app->allowlist[i] = app->allowlist[i + 1];
        }
        --app->allow_count;
        for(uint8_t i = 0; i < app->ap_count; ++i) {
            app->aps[i].allowlisted = defcon_is_allowlisted_locked(app, app->aps[i].bssid);
        }
        defcon_add_incident_locked(app, "ALLOWLIST REMOVE", removed, false);
    }
    furi_mutex_release(app->state_mutex);
    defcon_save_allowlist(app);
    defcon_rebuild_menu(app);
    defcon_switch_view(app, DefconViewMenu);
}

static bool defcon_custom_event(void* context, uint32_t event) {
    DefconApp* app = context;
    if(event == DefconEventOpenMenu) {
        defcon_log_ui(app, "main menu opened");
        defcon_rebuild_menu(app);
        defcon_switch_view(app, DefconViewMenu);
        return true;
    }
    if(event >= DefconEventMenuBase && event < DefconEventMenuBase + DefconMenuCount) {
        defcon_handle_menu(app, event - DefconEventMenuBase);
        return true;
    }
    if(event >= DefconEventListBase && event < DefconEventListBase + DEFCON_MAX_APS) {
        defcon_handle_list(app, event - DefconEventListBase);
        return true;
    }
    if(event == DefconEventEmergencyConfirm) {
        if(app->emergency) {
            defcon_start_monitoring(app);
        } else {
            defcon_stop_monitoring(app, true);
            furi_mutex_acquire(app->state_mutex, FuriWaitForever);
            defcon_add_incident_locked(
                app, "EMERGENCY MODE", "ESP Wi-Fi stopped; use trusted fallback", true);
            furi_mutex_release(app->state_mutex);
        }
        defcon_refresh_dashboard(app);
        defcon_switch_view(app, DefconViewDashboard);
        return true;
    }
    if(event == DefconEventEmergencyCancel) {
        defcon_rebuild_menu(app);
        defcon_switch_view(app, DefconViewMenu);
        return true;
    }
    return false;
}

static bool defcon_back_event(void* context) {
    DefconApp* app = context;
    if(app->current_view == DefconViewDashboard) {
        view_dispatcher_stop(app->dispatcher);
    } else if(app->current_view == DefconViewMenu) {
        defcon_refresh_dashboard(app);
        defcon_switch_view(app, DefconViewDashboard);
    } else {
        defcon_rebuild_menu(app);
        defcon_switch_view(app, DefconViewMenu);
    }
    return true;
}

static void defcon_tick(void* context) {
    DefconApp* app = context;
    const uint32_t now = furi_get_tick();

    furi_mutex_acquire(app->state_mutex, FuriWaitForever);
    const bool should_advance = app->monitoring && !app->emergency &&
                                defcon_tick_elapsed(now, app->phase_deadline);
    const bool was_running = app->phase_running;
    furi_mutex_release(app->state_mutex);

    if(should_advance) {
        if(was_running) {
            defcon_send_stop(app, false);
            furi_mutex_acquire(app->state_mutex, FuriWaitForever);
            app->phase_running = false;
            app->phase_deadline = now + furi_ms_to_ticks(DEFCON_PHASE_GAP_MS);
            furi_mutex_release(app->state_mutex);
        } else {
            furi_mutex_acquire(app->state_mutex, FuriWaitForever);
            app->phase = (app->phase + 1) % 3;
            furi_mutex_release(app->state_mutex);
            defcon_start_phase(app);
        }
    }

    if(!app->last_evidence_flush_tick ||
       defcon_tick_elapsed(now, app->last_evidence_flush_tick + furi_ms_to_ticks(1000))) {
        furi_mutex_acquire(app->state_mutex, FuriWaitForever);
        defcon_flush_evidence_locked(app);
        app->last_evidence_flush_tick = now;
        furi_mutex_release(app->state_mutex);
    }
    defcon_refresh_dashboard(app);
}

static void defcon_start_logging(DefconApp* app) {
    if(app->evidence_enabled) {
        defcon_queue_evidence_locked(app, "SESSION", "DEFCON Defense started");
        defcon_flush_evidence_locked(app);
    }
}

static DefconApp* defcon_app_alloc(void) {
    DefconApp* app = malloc(sizeof(DefconApp));
    memset(app, 0, sizeof(DefconApp));

    app->gui = furi_record_open(RECORD_GUI);
    app->storage = furi_record_open(RECORD_STORAGE);
    app->notification = furi_record_open(RECORD_NOTIFICATION);
    app->state_mutex = furi_mutex_alloc(FuriMutexTypeNormal);
    app->text = furi_string_alloc();

    storage_simply_mkdir(app->storage, DEFCON_APP_DIR);
    defcon_load_settings(app);
    defcon_load_allowlist(app);
    defcon_start_logging(app);

    app->dispatcher = view_dispatcher_alloc();
    view_dispatcher_set_event_callback_context(app->dispatcher, app);
    view_dispatcher_set_custom_event_callback(app->dispatcher, defcon_custom_event);
    view_dispatcher_set_navigation_event_callback(app->dispatcher, defcon_back_event);
    view_dispatcher_set_tick_event_callback(app->dispatcher, defcon_tick, 250);
    view_dispatcher_attach_to_gui(app->dispatcher, app->gui, ViewDispatcherTypeFullscreen);

    app->dashboard = view_alloc();
    view_set_context(app->dashboard, app);
    view_allocate_model(app->dashboard, ViewModelTypeLocking, sizeof(DefconDashboardModel));
    view_set_draw_callback(app->dashboard, defcon_dashboard_draw);
    view_set_input_callback(app->dashboard, defcon_dashboard_input);
    view_dispatcher_add_view(app->dispatcher, DefconViewDashboard, app->dashboard);

    app->menu = submenu_alloc();
    view_dispatcher_add_view(app->dispatcher, DefconViewMenu, submenu_get_view(app->menu));
    app->list = submenu_alloc();
    view_dispatcher_add_view(app->dispatcher, DefconViewList, submenu_get_view(app->list));
    app->text_box = text_box_alloc();
    view_dispatcher_add_view(app->dispatcher, DefconViewText, text_box_get_view(app->text_box));
    app->dialog = dialog_ex_alloc();
    view_dispatcher_add_view(app->dispatcher, DefconViewDialog, dialog_ex_get_view(app->dialog));

    app->current_view = DefconViewDashboard;
    app->phase = DefconPhaseAp;
    return app;
}

static void defcon_app_free(DefconApp* app) {
    if(!app) return;
    defcon_stop_monitoring(app, false);
    if(app->evidence_enabled) {
        furi_mutex_acquire(app->state_mutex, FuriWaitForever);
        defcon_queue_evidence_locked(app, "SESSION", "DEFCON Defense stopped");
        defcon_flush_evidence_locked(app);
        furi_mutex_release(app->state_mutex);
    }

    if(app->uart) defcon_uart_free(app->uart);

    view_dispatcher_remove_view(app->dispatcher, DefconViewDashboard);
    view_dispatcher_remove_view(app->dispatcher, DefconViewMenu);
    view_dispatcher_remove_view(app->dispatcher, DefconViewList);
    view_dispatcher_remove_view(app->dispatcher, DefconViewText);
    view_dispatcher_remove_view(app->dispatcher, DefconViewDialog);
    view_free(app->dashboard);
    submenu_free(app->menu);
    submenu_free(app->list);
    text_box_free(app->text_box);
    dialog_ex_free(app->dialog);
    view_dispatcher_free(app->dispatcher);

    furi_string_free(app->text);
    furi_mutex_free(app->state_mutex);
    furi_record_close(RECORD_NOTIFICATION);
    furi_record_close(RECORD_STORAGE);
    furi_record_close(RECORD_GUI);
    free(app);
}

int32_t defcon_defense_app(void* context) {
    UNUSED(context);

    Expansion* expansion = furi_record_open(RECORD_EXPANSION);
    expansion_disable(expansion);
    const bool otg_was_enabled = furi_hal_power_is_otg_enabled();
    uint8_t attempts = 0;
    while(!furi_hal_power_is_otg_enabled() && attempts++ < 5) {
        furi_hal_power_enable_otg();
        furi_delay_ms(10);
    }
    furi_delay_ms(200);

    DefconApp* app = defcon_app_alloc();
    app->uart = defcon_uart_alloc(defcon_uart_rx, app);
    defcon_start_monitoring(app);
    defcon_refresh_dashboard(app);
    defcon_switch_view(app, DefconViewDashboard);
    view_dispatcher_run(app->dispatcher);
    defcon_app_free(app);

    if(furi_hal_power_is_otg_enabled() && !otg_was_enabled) furi_hal_power_disable_otg();
    expansion_enable(expansion);
    furi_record_close(RECORD_EXPANSION);
    return 0;
}
