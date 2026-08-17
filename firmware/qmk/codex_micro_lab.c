/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "codex_micro_lab.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "eeconfig.h"
#include "raw_hid.h"
#include "rgb_matrix.h"
#include "timer.h"

#ifdef KC_BLUETOOTH_ENABLE
#    include "battery.h"
#    include "transport.h"
#endif

#define CM_CODEX_REPORT_ID 0x06
#define CM_CONFIG_REPORT_ID 0x07
#define CM_RPC_CHANNEL 0x02
#define CM_CONFIG_MAGIC 0xA7
#define CM_CONFIG_VERSION 0x01

#define CM_CONFIG_HELLO 0x01
#define CM_CONFIG_MAPPINGS 0x02
#define CM_CONFIG_CAPTURE 0x03
#define CM_CONFIG_SET 0x04
#define CM_CONFIG_CLEAR 0x05
#define CM_CONFIG_ENCODER 0x06
#define CM_CONFIG_RESET 0x07
#define CM_CONFIG_CAPTURED 0x13
#define CM_CONFIG_ACK 0x7F

#define CM_STATUS_OK 0
#define CM_STATUS_BAD_LENGTH 1
#define CM_STATUS_BAD_TARGET 2
#define CM_STATUS_BAD_POSITION 3

#define CM_TARGET_AGENT_FIRST 0
#define CM_TARGET_COMMAND_FIRST 6
#define CM_TARGET_ENCODER_PRESS 12
#define CM_TARGET_JOYSTICK_UP 13
#define CM_TARGET_JOYSTICK_RIGHT 14
#define CM_TARGET_JOYSTICK_DOWN 15
#define CM_TARGET_JOYSTICK_LEFT 16

#define CM_MAPPING_UNASSIGNED 0xFF
#define CM_CONFIG_MAGIC_0 0x43
#define CM_CONFIG_MAGIC_1 0x4D
#define CM_CONFIG_STORAGE_VERSION 2
#define CM_JSON_BUFFER_SIZE 1536
#define CM_EVENT_QUEUE_SIZE 16
#define CM_CAPTURE_TIMEOUT_MS 30000

#define CM_EFFECT_OFF 0
#define CM_EFFECT_SOLID 1
#define CM_EFFECT_SNAKE 2
#define CM_EFFECT_RAINBOW 3
#define CM_EFFECT_BREATH 4
#define CM_EFFECT_GRADIENT 5
#define CM_EFFECT_SHALLOW_BREATH 6
#define CM_EFFECT_LAST CM_EFFECT_SHALLOW_BREATH

/*
 * Codex Micro reports brightness, speed, and effect-specific magic as
 * normalized values. Preserve them as 8-bit state; brightness 0 is off and
 * speed 0 is still. The timing tick and snake width below are Q6-specific
 * visual calibration, not vendor firmware values.
 */
#define CM_ANIMATION_TICK_MS 8
#define CM_SNAKE_WIDTH 32

typedef struct PACKED {
    uint8_t row;
    uint8_t col;
} cm_mapping_t;

typedef struct PACKED {
    uint8_t magic_0;
    uint8_t magic_1;
    uint8_t version;
    uint8_t encoder_enabled;
    cm_mapping_t mappings[CM_TARGET_COUNT];
    uint8_t checksum;
} cm_persisted_config_t;

_Static_assert(sizeof(cm_persisted_config_t) <= EECONFIG_USER_DATA_SIZE, "Codex Micro lab mapping storage exceeds QMK user EEPROM block");

typedef struct {
    uint32_t color;
    uint8_t brightness;
    uint8_t effect;
    uint8_t speed;
    uint8_t magic;
    bool sync_keys;
    bool sync_ambient;
    uint32_t started_at;
} cm_light_t;

typedef enum {
    CM_EVENT_HID,
    CM_EVENT_JOYSTICK,
    CM_EVENT_CAPTURED,
} cm_event_kind_t;

typedef struct {
    cm_event_kind_t kind;
    uint8_t target;
    uint8_t action;
    uint8_t row;
    uint8_t col;
} cm_event_t;

static cm_persisted_config_t config;
static bool config_loaded;
static bool desktop_connected;
static char json_buffer[CM_JSON_BUFFER_SIZE];
static uint16_t json_length;

static cm_light_t slots[6];
static cm_light_t keys_light;
static cm_light_t ambient_light;
static uint32_t render_time;

static cm_event_t events[CM_EVENT_QUEUE_SIZE];
static uint8_t event_head;
static uint8_t event_tail;
static uint8_t event_count;

static bool capture_active;
static uint8_t capture_target;
static uint32_t capture_started_at;
static bool capture_release_suppressed;
static uint8_t capture_row;
static uint8_t capture_col;

/*
 * Native Micro target order:
 *   0...5   Agent 1...6
 *   6...11  Fast, Approve, Decline, Continue, PTT, Send
 *   12      Encoder press
 *   13...16 Joystick directions (not present on the Q6 Pro)
 *
 * Encoder rotation is intentionally not part of this table. It is permanently
 * claimed by codex_micro_lab_encoder_preprocess() while the keyboard uses USB.
 */
static const cm_mapping_t default_mappings[CM_TARGET_COUNT] = {
    [0] = {4, 17},
    [1] = {4, 18},
    [2] = {4, 19},
    [3] = {3, 17},
    [4] = {3, 18},
    [5] = {3, 19},
    [6] = {2, 20},
    [7] = {0, 17},
    [8] = {0, 20},
    [9] = {0, 18},
    [10] = {5, 18},
    [11] = {4, 20},
    [12] = {0, 13},
    [13] = {CM_MAPPING_UNASSIGNED, CM_MAPPING_UNASSIGNED},
    [14] = {CM_MAPPING_UNASSIGNED, CM_MAPPING_UNASSIGNED},
    [15] = {CM_MAPPING_UNASSIGNED, CM_MAPPING_UNASSIGNED},
    [16] = {CM_MAPPING_UNASSIGNED, CM_MAPPING_UNASSIGNED},
};

static uint8_t config_checksum(const cm_persisted_config_t *value) {
    const uint8_t *bytes = (const uint8_t *)value;
    uint8_t checksum = 0x5A;
    for (uint8_t i = 0; i < sizeof(*value) - 1; i++) checksum ^= bytes[i];
    return checksum;
}

static void config_defaults(void) {
    memset(&config, 0, sizeof(config));
    config.magic_0 = CM_CONFIG_MAGIC_0;
    config.magic_1 = CM_CONFIG_MAGIC_1;
    config.version = CM_CONFIG_STORAGE_VERSION;
    config.encoder_enabled = 1;
    memcpy(config.mappings, default_mappings, sizeof(config.mappings));
    config.checksum = config_checksum(&config);
}

static void save_config(void) {
    config.checksum = config_checksum(&config);
    eeconfig_update_user_datablock(&config);
}

static void ensure_config(void) {
    if (config_loaded) return;
    eeconfig_read_user_datablock(&config);
    if (config.magic_0 != CM_CONFIG_MAGIC_0 || config.magic_1 != CM_CONFIG_MAGIC_1 ||
        config.version != CM_CONFIG_STORAGE_VERSION || config.checksum != config_checksum(&config)) {
        config_defaults();
        save_config();
    } else if (config.encoder_enabled != 1) {
        /* Old or externally modified data may never disable Micro rotation. */
        config.encoder_enabled = 1;
        save_config();
    }
    config_loaded = true;
}

void eeconfig_init_user_datablock(void) {
    config_defaults();
    save_config();
    config_loaded = true;
}

static bool using_usb(void) {
#ifdef KC_BLUETOOTH_ENABLE
    return get_transport() == TRANSPORT_USB;
#else
    return true;
#endif
}

static void send_report(uint8_t report_id, uint8_t byte_1, uint8_t byte_2, uint8_t byte_3, uint8_t byte_4, uint8_t byte_5, const uint8_t *payload, uint8_t payload_length) {
    uint8_t report[CM_REPORT_SIZE] = {report_id, byte_1, byte_2, byte_3, byte_4, byte_5};
    if (payload_length > CM_REPORT_SIZE - 6) payload_length = CM_REPORT_SIZE - 6;
    if (payload_length > 0) memcpy(&report[6], payload, payload_length);
    raw_hid_send(report, sizeof(report));
}

static void send_config(uint8_t opcode, uint8_t sequence, const uint8_t *payload, uint8_t payload_length) {
    send_report(CM_CONFIG_REPORT_ID, CM_CONFIG_MAGIC, CM_CONFIG_VERSION, opcode, sequence, payload_length, payload, payload_length);
}

static void send_config_ack(uint8_t sequence, uint8_t opcode, uint8_t status) {
    uint8_t payload[2] = {opcode, status};
    send_config(CM_CONFIG_ACK, sequence, payload, sizeof(payload));
}

static void send_json(const char *message) {
    size_t length = strlen(message);
    size_t offset = 0;
    while (offset <= length) {
        uint8_t payload[61];
        uint8_t count = 0;
        while (count < sizeof(payload) && offset < length) payload[count++] = (uint8_t)message[offset++];
        if (offset == length && count < sizeof(payload)) {
            payload[count++] = '\n';
            offset++;
        }
        uint8_t report[CM_REPORT_SIZE] = {CM_CODEX_REPORT_ID, CM_RPC_CHANNEL, count};
        memcpy(&report[3], payload, count);
        raw_hid_send(report, sizeof(report));
        if (offset > length) break;
    }
}

static bool enqueue_event(cm_event_kind_t kind, uint8_t target, uint8_t action, uint8_t row, uint8_t col) {
    if (event_count >= CM_EVENT_QUEUE_SIZE) return false;
    events[event_tail] = (cm_event_t){kind, target, action, row, col};
    event_tail = (uint8_t)((event_tail + 1) % CM_EVENT_QUEUE_SIZE);
    event_count++;
    return true;
}

static const char *command_key(uint8_t target) {
    static const char *const keys[6] = {"ACT06", "ACT07", "ACT08", "ACT09", "ACT10", "ACT12"};
    return target < 6 ? keys[target] : "ACT06";
}

static void send_hid_event(const cm_event_t *event) {
    char message[96];
    if (event->target == CM_TARGET_ENCODER_PRESS && event->action == 2) {
        snprintf(message, sizeof(message), "{\"method\":\"v.oai.hid\",\"params\":{\"k\":\"%s\",\"act\":2,\"ag\":0}}", event->row == 0 ? "ENC_CW" : "ENC_CC");
    } else if (event->target < 6) {
        snprintf(message, sizeof(message), "{\"method\":\"v.oai.hid\",\"params\":{\"k\":\"AG0%u\",\"act\":%u,\"ag\":%u}}", event->target, event->action, event->target);
    } else if (event->target < 12) {
        snprintf(message, sizeof(message), "{\"method\":\"v.oai.hid\",\"params\":{\"k\":\"%s\",\"act\":%u,\"ag\":0}}", command_key(event->target - 6), event->action);
    } else {
        snprintf(message, sizeof(message), "{\"method\":\"v.oai.hid\",\"params\":{\"k\":\"ENC_PRESS\",\"act\":%u,\"ag\":0}}", event->action);
    }
    send_json(message);
}

static void send_joystick_event(const cm_event_t *event) {
    static const uint16_t angles[4] = {90, 0, 270, 180};
    uint8_t direction = event->target - CM_TARGET_JOYSTICK_UP;
    char message[80];
    snprintf(message, sizeof(message), "{\"method\":\"v.oai.rad\",\"params\":{\"a\":%u,\"d\":%u}}", angles[direction], event->action ? 1 : 0);
    send_json(message);
}

static void send_capture_event(const cm_event_t *event) {
    uint8_t payload[4] = {event->target, event->row, event->col, 0xFF};
    if (event->row < MATRIX_ROWS && event->col < MATRIX_COLS) payload[3] = g_led_config.matrix_co[event->row][event->col];
    send_config(CM_CONFIG_CAPTURED, 0, payload, sizeof(payload));
}

static void drain_event(void) {
    if (event_count == 0 || !using_usb()) return;
    cm_event_t event = events[event_head];
    event_head = (uint8_t)((event_head + 1) % CM_EVENT_QUEUE_SIZE);
    event_count--;
    if (event.kind == CM_EVENT_HID && desktop_connected) send_hid_event(&event);
    if (event.kind == CM_EVENT_JOYSTICK && desktop_connected) send_joystick_event(&event);
    if (event.kind == CM_EVENT_CAPTURED) send_capture_event(&event);
}

static const char *find_last(const char *text, const char *needle) {
    const char *found = NULL;
    const char *cursor = text;
    while ((cursor = strstr(cursor, needle)) != NULL) {
        found = cursor;
        cursor += strlen(needle);
    }
    return found;
}

static int request_id(const char *json) {
    const char *id = find_last(json, "\"id\":");
    return id == NULL ? 0 : atoi(id + 5);
}

static bool json_complete(const char *json, uint16_t length) {
    int16_t depth = 0;
    bool in_string = false;
    bool escaped = false;
    bool started = false;
    for (uint16_t i = 0; i < length; i++) {
        char ch = json[i];
        if (in_string) {
            if (escaped) escaped = false;
            else if (ch == '\\') escaped = true;
            else if (ch == '"') in_string = false;
            continue;
        }
        if (ch == '"') in_string = true;
        else if (ch == '{' || ch == '[') {
            depth++;
            started = true;
        } else if (ch == '}' || ch == ']') {
            depth--;
        }
    }
    return started && depth == 0 && !in_string;
}

static const char *find_bounded(const char *start, const char *end, const char *needle) {
    const char *match = strstr(start, needle);
    return match != NULL && match < end ? match : NULL;
}

static uint32_t parse_uint_after(const char *position, const char *key, uint32_t fallback) {
    if (position == NULL) return fallback;
    const char *value = position + strlen(key);
    while (*value == ' ' || *value == ':') value++;
    return (uint32_t)strtoul(value, NULL, 10);
}

static uint8_t parse_unit_after(const char *position, const char *key, uint8_t fallback) {
    if (position == NULL) return fallback;
    const char *value = position + strlen(key);
    while (*value == ' ' || *value == ':') value++;
    uint32_t whole = 0;
    while (*value >= '0' && *value <= '9') whole = whole * 10 + (uint32_t)(*value++ - '0');
    if (*value != '.') return whole > 0 ? 255 : 0;
    value++;
    uint32_t fraction = 0;
    uint32_t scale = 1;
    for (uint8_t i = 0; i < 3 && *value >= '0' && *value <= '9'; i++) {
        fraction = fraction * 10 + (uint32_t)(*value++ - '0');
        scale *= 10;
    }
    uint32_t result = whole * 255 + fraction * 255 / scale;
    return result > 255 ? 255 : (uint8_t)result;
}

static bool parse_flag_after(const char *position, const char *key, bool fallback) {
    if (position == NULL) return fallback;
    const char *value = position + strlen(key);
    while (*value == ' ' || *value == ':') value++;
    if (*value == '1' || strncmp(value, "true", 4) == 0) return true;
    if (*value == '0' || strncmp(value, "false", 5) == 0) return false;
    return fallback;
}

static void parse_light_object(const char *start, const char *end, cm_light_t *light) {
    cm_light_t next = *light;
    next.color = parse_uint_after(find_bounded(start, end, "\"c\":"), "\"c\":", next.color);
    next.brightness = parse_unit_after(find_bounded(start, end, "\"b\":"), "\"b\":", next.brightness);
    uint32_t effect = parse_uint_after(find_bounded(start, end, "\"e\":"), "\"e\":", next.effect);
    next.effect = effect <= CM_EFFECT_LAST ? (uint8_t)effect : CM_EFFECT_OFF;
    next.speed = parse_unit_after(find_bounded(start, end, "\"s\":"), "\"s\":", next.speed);
    next.magic = parse_unit_after(find_bounded(start, end, "\"m\":"), "\"m\":", next.magic);
    next.sync_keys = parse_flag_after(find_bounded(start, end, "\"sk\":"), "\"sk\":", next.sync_keys);
    next.sync_ambient = parse_flag_after(find_bounded(start, end, "\"sa\":"), "\"sa\":", next.sync_ambient);

    if (next.color != light->color || next.brightness != light->brightness || next.effect != light->effect || next.speed != light->speed) {
        next.started_at = timer_read32();
    }
    *light = next;
}

static void parse_threads_lighting(const char *json) {
    const char *cursor = strstr(json, "\"params\":[");
    if (cursor == NULL) return;
    while ((cursor = strstr(cursor, "{\"id\":")) != NULL) {
        const char *end = strchr(cursor, '}');
        if (end == NULL) break;
        uint8_t id = (uint8_t)parse_uint_after(cursor, "{\"id\":", 0xFF);
        if (id < 6) parse_light_object(cursor, end, &slots[id]);
        cursor = end + 1;
    }
    rgb_matrix_enable_noeeprom();
}

static void parse_named_light(const char *json, const char *name, cm_light_t *light) {
    const char *name_position = strstr(json, name);
    if (name_position == NULL) return;
    const char *start = strchr(name_position, '{');
    const char *end = start == NULL ? NULL : strchr(start, '}');
    if (start != NULL && end != NULL) parse_light_object(start, end, light);
}

static void parse_rgb_config(const char *json) {
    parse_named_light(json, "\"ambient\"", &ambient_light);
    parse_named_light(json, "\"keys\"", &keys_light);
    rgb_matrix_enable_noeeprom();
}

static void handle_json_request(char *json) {
    int id = request_id(json);
    char response[192];
    desktop_connected = true;
    if (strstr(json, "\"method\":\"sys.version\"") != NULL) {
        snprintf(response, sizeof(response), "{\"id\":%d,\"result\":{\"version\":\"0.1.5-arkey-lab\"}}", id);
    } else if (strstr(json, "\"method\":\"device.status\"") != NULL) {
#ifdef KC_BLUETOOTH_ENABLE
        uint8_t battery = battery_get_percentage();
#else
        uint8_t battery = 100;
#endif
        snprintf(response, sizeof(response), "{\"id\":%d,\"result\":{\"version\":\"0.1.5-arkey-lab\",\"profile_index\":0,\"layer_index\":0,\"battery\":%u,\"is_charging\":true}}", id, battery);
    } else if (strstr(json, "\"method\":\"v.oai.thstatus\"") != NULL) {
        parse_threads_lighting(json);
        snprintf(response, sizeof(response), "{\"id\":%d,\"result\":true}", id);
    } else if (strstr(json, "\"method\":\"v.oai.rgbcfg\"") != NULL) {
        parse_rgb_config(json);
        snprintf(response, sizeof(response), "{\"id\":%d,\"result\":true}", id);
    } else {
        snprintf(response, sizeof(response), "{\"id\":%d,\"result\":true}", id);
    }
    send_json(response);
}

static bool handle_codex_report(const uint8_t *data, uint8_t length) {
    if (length != CM_REPORT_SIZE || data[0] != CM_CODEX_REPORT_ID || data[1] != CM_RPC_CHANNEL) return false;
    uint8_t count = data[2] > 61 ? 61 : data[2];
    if ((uint32_t)json_length + count >= sizeof(json_buffer)) {
        json_length = 0;
        return true;
    }
    memcpy(&json_buffer[json_length], &data[3], count);
    json_length += count;
    json_buffer[json_length] = '\0';
    if (json_complete(json_buffer, json_length)) {
        handle_json_request(json_buffer);
        json_length = 0;
        json_buffer[0] = '\0';
    }
    return true;
}

static bool valid_position(uint8_t row, uint8_t col) {
    // Some physical controls, including the Q6 Pro encoder press, have no RGB LED.
    // They remain valid Micro targets; set_mapped_color() simply skips their lighting.
    return row < MATRIX_ROWS && col < MATRIX_COLS;
}

static void unassign_position(uint8_t except_target, uint8_t row, uint8_t col) {
    for (uint8_t i = 0; i < CM_TARGET_COUNT; i++) {
        if (i != except_target && config.mappings[i].row == row && config.mappings[i].col == col) {
            config.mappings[i].row = CM_MAPPING_UNASSIGNED;
            config.mappings[i].col = CM_MAPPING_UNASSIGNED;
        }
    }
}

static void assign_mapping(uint8_t target, uint8_t row, uint8_t col) {
    unassign_position(target, row, col);
    config.mappings[target].row = row;
    config.mappings[target].col = col;
    save_config();
}

static void send_mappings(uint8_t sequence) {
    uint8_t payload[2 + CM_TARGET_COUNT * 3] = {CM_TARGET_COUNT, config.encoder_enabled};
    for (uint8_t i = 0; i < CM_TARGET_COUNT; i++) {
        payload[2 + i * 3] = i;
        payload[3 + i * 3] = config.mappings[i].row;
        payload[4 + i * 3] = config.mappings[i].col;
    }
    send_config(CM_CONFIG_MAPPINGS, sequence, payload, sizeof(payload));
}

static bool handle_config_report(const uint8_t *data, uint8_t length) {
    if (length != CM_REPORT_SIZE || data[0] != CM_CONFIG_REPORT_ID || data[1] != CM_CONFIG_MAGIC || data[2] != CM_CONFIG_VERSION) return false;
    ensure_config();
    uint8_t opcode = data[3];
    uint8_t sequence = data[4];
    uint8_t payload_length = data[5];
    const uint8_t *payload = &data[6];
    if (payload_length > CM_REPORT_SIZE - 6) {
        send_config_ack(sequence, opcode, CM_STATUS_BAD_LENGTH);
        return true;
    }
    switch (opcode) {
        case CM_CONFIG_HELLO: {
            uint8_t info[5] = {CM_TARGET_COUNT, MATRIX_ROWS, MATRIX_COLS, config.encoder_enabled, RGB_MATRIX_LED_COUNT};
            send_config(CM_CONFIG_HELLO, sequence, info, sizeof(info));
            break;
        }
        case CM_CONFIG_MAPPINGS:
            send_mappings(sequence);
            break;
        case CM_CONFIG_CAPTURE:
            if (payload_length != 1) send_config_ack(sequence, opcode, CM_STATUS_BAD_LENGTH);
            else if (payload[0] >= CM_TARGET_COUNT) send_config_ack(sequence, opcode, CM_STATUS_BAD_TARGET);
            else {
                capture_target = payload[0];
                capture_started_at = timer_read32();
                capture_active = true;
                send_config_ack(sequence, opcode, CM_STATUS_OK);
            }
            break;
        case CM_CONFIG_SET:
            if (payload_length != 3) send_config_ack(sequence, opcode, CM_STATUS_BAD_LENGTH);
            else if (payload[0] >= CM_TARGET_COUNT) send_config_ack(sequence, opcode, CM_STATUS_BAD_TARGET);
            else if (!valid_position(payload[1], payload[2])) send_config_ack(sequence, opcode, CM_STATUS_BAD_POSITION);
            else {
                assign_mapping(payload[0], payload[1], payload[2]);
                send_config_ack(sequence, opcode, CM_STATUS_OK);
            }
            break;
        case CM_CONFIG_CLEAR:
            if (payload_length != 1) send_config_ack(sequence, opcode, CM_STATUS_BAD_LENGTH);
            else if (payload[0] >= CM_TARGET_COUNT) send_config_ack(sequence, opcode, CM_STATUS_BAD_TARGET);
            else {
                config.mappings[payload[0]].row = CM_MAPPING_UNASSIGNED;
                config.mappings[payload[0]].col = CM_MAPPING_UNASSIGNED;
                save_config();
                send_config_ack(sequence, opcode, CM_STATUS_OK);
            }
            break;
        case CM_CONFIG_ENCODER:
            if (payload_length != 1) send_config_ack(sequence, opcode, CM_STATUS_BAD_LENGTH);
            else {
                /* The compatibility surface owns the encoder on USB. A legacy
                 * "disable" request is acknowledged but deliberately ignored. */
                (void)payload;
                if (config.encoder_enabled != 1) {
                    config.encoder_enabled = 1;
                    save_config();
                }
                send_config_ack(sequence, opcode, CM_STATUS_OK);
            }
            break;
        case CM_CONFIG_RESET:
            config_defaults();
            save_config();
            send_config_ack(sequence, opcode, CM_STATUS_OK);
            break;
        default:
            send_config_ack(sequence, opcode, CM_STATUS_BAD_TARGET);
            break;
    }
    return true;
}

bool codex_micro_lab_command(uint8_t *data, uint8_t length) {
    if (!using_usb()) return false;
    if (handle_codex_report(data, length)) return true;
    if (handle_config_report(data, length)) return true;
    return false;
}

static int8_t target_for_position(uint8_t row, uint8_t col) {
    for (uint8_t i = 0; i < CM_TARGET_COUNT; i++) {
        if (config.mappings[i].row == row && config.mappings[i].col == col) return (int8_t)i;
    }
    return -1;
}

static void expire_capture_if_needed(void) {
    if (capture_active && timer_elapsed32(capture_started_at) >= CM_CAPTURE_TIMEOUT_MS) {
        capture_active = false;
    }
}

static bool handle_matrix_record(keyrecord_t *record) {
    uint8_t row = record->event.key.row;
    uint8_t col = record->event.key.col;
    bool pressed = record->event.pressed;

    // The host-side capture command also waits for 30 seconds, but the device
    // must enforce its own deadline. Otherwise closing a timed-out client would
    // leave the next unrelated keypress armed for capture and suppress it.
    expire_capture_if_needed();

    if (!pressed && capture_release_suppressed && row == capture_row && col == capture_col) {
        capture_release_suppressed = false;
        return false;
    }

    if (pressed && capture_active) {
        capture_active = false;
        capture_release_suppressed = true;
        capture_row = row;
        capture_col = col;
        assign_mapping(capture_target, row, col);
        enqueue_event(CM_EVENT_CAPTURED, capture_target, 1, row, col);
        return false;
    }

    int8_t target = target_for_position(row, col);
    if (target < 0) return true;
    if (target <= CM_TARGET_ENCODER_PRESS) enqueue_event(CM_EVENT_HID, (uint8_t)target, pressed ? 1 : 0, row, col);
    else enqueue_event(CM_EVENT_JOYSTICK, (uint8_t)target, pressed ? 1 : 0, row, col);
    return false;
}

bool codex_micro_lab_process_record(uint16_t keycode, keyrecord_t *record) {
    (void)keycode;
    ensure_config();
    if (!using_usb()) return true;
    if (record->event.key.row < MATRIX_ROWS && record->event.key.col < MATRIX_COLS) return handle_matrix_record(record);
    return true;
}

bool codex_micro_lab_encoder_preprocess(uint8_t index, bool clockwise) {
    ensure_config();
    if (!using_usb()) return true;

    // Claim the turn before ENCODER_MAP emits KC_VOLD/KC_VOLU. Q6 Pro's
    // encoder orientation is opposite to the Codex Micro protocol direction,
    // so normalize it here before task() emits ENC_CW or ENC_CC.
    enqueue_event(CM_EVENT_HID, CM_TARGET_ENCODER_PRESS, 2, clockwise ? 1 : 0, index);
    return false;
}

void codex_micro_lab_task(void) {
    ensure_config();
    if (!using_usb()) {
        desktop_connected = false;
        json_length = 0;
        event_head = event_tail = event_count = 0;
        capture_active = false;
        return;
    }
    expire_capture_if_needed();
    drain_event();
}

static uint8_t light_phase(const cm_light_t *light, uint32_t now) {
    if (light->speed == 0) return 0;
    uint16_t ticks = (uint16_t)((now - light->started_at) / CM_ANIMATION_TICK_MS);
    return (uint8_t)((uint32_t)ticks * light->speed >> 8);
}

static uint8_t triangle(uint8_t phase) {
    return phase < 128 ? (uint8_t)(phase * 2) : (uint8_t)(255 - (phase - 128) * 2);
}

static uint8_t smooth_breath_wave(uint8_t phase) {
    uint32_t ramp = triangle((uint8_t)(phase * 2));
    return (uint8_t)(ramp * ramp * (765 - 2 * ramp) / 65025);
}

static uint8_t led_strip_position(uint8_t led) {
#if RGB_MATRIX_LED_COUNT <= 1
    (void)led;
    return 0;
#else
    return (uint8_t)((uint16_t)led * 255 / (RGB_MATRIX_LED_COUNT - 1));
#endif
}

static uint8_t circular_distance(uint8_t left, uint8_t right) {
    uint8_t distance = left > right ? left - right : right - left;
    return distance > 128 ? (uint8_t)(256 - distance) : distance;
}

static RGB scaled_color(uint32_t color, uint8_t value) {
    uint8_t red = (uint8_t)(color >> 16);
    uint8_t green = (uint8_t)(color >> 8);
    uint8_t blue = (uint8_t)color;
    return (RGB){(uint8_t)((uint16_t)red * value / 255), (uint8_t)((uint16_t)green * value / 255), (uint8_t)((uint16_t)blue * value / 255)};
}

static RGB render_light(const cm_light_t *light, uint8_t led, uint32_t now) {
    uint8_t value = light->brightness;
    if (light->effect == CM_EFFECT_OFF || value == 0) return (RGB){0, 0, 0};

    uint8_t phase = light_phase(light, now);
    if (light->effect == CM_EFFECT_BREATH || light->effect == CM_EFFECT_SHALLOW_BREATH) {
        uint8_t wave = smooth_breath_wave(phase);
        if (light->effect == CM_EFFECT_SHALLOW_BREATH) wave = (uint8_t)(128 + wave / 2);
        value = (uint8_t)((uint16_t)value * wave / 255);
    } else if (light->effect == CM_EFFECT_SNAKE) {
        uint8_t head = (uint8_t)(phase * 2);
        uint8_t distance = circular_distance(led_strip_position(led), head);
        uint8_t wave = distance < CM_SNAKE_WIDTH ? (uint8_t)((uint16_t)(CM_SNAKE_WIDTH - distance) * 255 / CM_SNAKE_WIDTH) : 0;
        value = (uint8_t)((uint16_t)value * wave / 255);
    } else if (light->effect == CM_EFFECT_RAINBOW) {
        HSV hsv = {(uint8_t)(led_strip_position(led) + phase), 255, value};
        return hsv_to_rgb(hsv);
    } else if (light->effect == CM_EFFECT_GRADIENT) {
        uint8_t wave = (uint8_t)(128 + triangle((uint8_t)(led_strip_position(led) + phase)) / 2);
        value = (uint8_t)((uint16_t)value * wave / 255);
    }
    return scaled_color(light->color, value);
}

static void set_mapped_color(uint8_t target, const cm_light_t *light, uint8_t led_min, uint8_t led_max, uint32_t now) {
    cm_mapping_t mapping = config.mappings[target];
    if (mapping.row >= MATRIX_ROWS || mapping.col >= MATRIX_COLS) return;
    uint8_t led = g_led_config.matrix_co[mapping.row][mapping.col];
    if (led == NO_LED || led < led_min || led >= led_max) return;
    RGB rgb = render_light(light, led, now);
    rgb_matrix_set_color(led, rgb.r, rgb.g, rgb.b);
}

bool rgb_matrix_indicators_advanced_kb(uint8_t led_min, uint8_t led_max) {
    ensure_config();
    if (using_usb() && desktop_connected) {
        if (led_min == 0 || render_time == 0) render_time = timer_read32();
        for (uint8_t led = led_min; led < led_max; led++) {
            RGB rgb = render_light(&ambient_light, led, render_time);
            rgb_matrix_set_color(led, rgb.r, rgb.g, rgb.b);
        }
        for (uint8_t target = CM_TARGET_COMMAND_FIRST; target <= CM_TARGET_ENCODER_PRESS; target++) set_mapped_color(target, &keys_light, led_min, led_max, render_time);
        for (uint8_t slot = 0; slot < 6; slot++) set_mapped_color(slot, &slots[slot], led_min, led_max, render_time);
    }
    return rgb_matrix_indicators_advanced_user(led_min, led_max);
}
