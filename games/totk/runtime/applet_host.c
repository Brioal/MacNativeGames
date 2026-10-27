/* Host side of applet, telemetry, NFC and error-display services that main reaches through IPC.
   Client-side SDK code (PlayReport encoding, keyboard presets, diag logging) runs unchanged; only the
   calls that would talk to system services are taken here. */
#include "runtime.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* ---------- nn::oe ---------- */
static float balance[2] = {1.0f, 1.0f};
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t message_cv = PTHREAD_COND_INITIALIZER;
static uint32_t messages[32]; static unsigned head, tail;
static uint64_t start_ns;
__attribute__((constructor)) static void started(void) { start_ns = runtime_now_ns(); }

void runtime_oe_push_message(uint32_t message) {
    pthread_mutex_lock(&lock);
    if (tail - head < 32) { messages[tail++ % 32] = message; pthread_cond_broadcast(&message_cv); }
    pthread_mutex_unlock(&lock);
}
static void get_balance(float *l, float *r) { pthread_mutex_lock(&lock); if (l) *l = balance[0]; if (r) *r = balance[1]; pthread_mutex_unlock(&lock); }
static void set_balance(float l, float r) {
    if (l < 0 || l > 1 || r < 0 || r > 1) runtime_fail("volume balance out of range");
    pthread_mutex_lock(&lock); balance[0] = l; balance[1] = r; pthread_mutex_unlock(&lock);
}
static int64_t total_active_time(void) { return (int64_t)(runtime_now_ns() - start_ns); }   /* TimeSpan in ns */
/* The host never sleeps the console; the extended inactivity window has no further effect. */
static void inactivity_extended(unsigned char on) { (void)on; }
/* No system startup logo is drawn on the host, so there is nothing to dismiss. */
static void finish_startup_logo(void) { fprintf(stderr, "[totk] game finished startup logo\n"); }
/* The single native executable was launched directly; it has no predecessor
 * in an applet ExecuteProgram chain. -1 keeps the game's normal user-open path. */
static int previous_program_index(void) { return -1; }
/* A stable, nonzero resource id for this process's one application. Host input
 * and audio share that application; there is no separate system applet client. */
static uint64_t applet_resource_user_id(void) { return 1; }
static unsigned char try_pop_launch_parameter(uint64_t *size,void *buffer,uint64_t capacity) {
    (void)buffer;(void)capacity;if(size)*size=0;return 0;
}
static unsigned char try_pop(uint32_t *out) {
    pthread_mutex_lock(&lock); int ok = head != tail; if (ok && out) *out = messages[head++ % 32]; pthread_mutex_unlock(&lock); return (unsigned char)ok;
}
int runtime_core_away(void); void runtime_core_back(int *away);
static uint32_t pop(void) {
    __attribute__((cleanup(runtime_core_back))) int away = runtime_core_away();   /* blocks like a Horizon wait */
    pthread_mutex_lock(&lock); while (head == tail) pthread_cond_wait(&message_cv, &lock);
    uint32_t m = messages[head++ % 32]; pthread_mutex_unlock(&lock); return m;
}

/* ---------- nn::prepo: play reports are not transmitted (no Nintendo servers) ---------- */
static uint64_t reports;
static unsigned report_save(const void *report) { (void)report; if (!(reports++ % 100)) fprintf(stderr, "[totk] play report kept local (not transmitted), count %llu\n", (unsigned long long)reports); return 0; }
static unsigned report_save_uid(const void *report, const void *uid) { (void)uid; return report_save(report); }
static unsigned immediate_transmission(void) { return 0; }
static unsigned connection_status(void *report, const char *a, const char *b, const char *c) { (void)report; (void)a; (void)b; (void)c; return 0; }

/* ---------- nn::nfp: virtual Amiibo for Breath of the Wild 1.6.0 ---------- */
#define NFP_DEVICE_NOT_FOUND 0x8073u   /* nfp module 115, description 64 */
static int nfp_state;
static unsigned nfp_initialize(void) { nfp_state = 1; return 0; }
static unsigned nfp_finalize(void) { nfp_state = 0; return 0; }
static int nfp_get_state(void) { return nfp_state; }
#ifdef GAME_BOTW160
typedef struct { uint16_t year; uint8_t month, day; } NfpDateHost;
typedef struct {
    uint8_t uid[10], uid_length, reserved[0x15];
    uint32_t protocol, tag_type;
    uint8_t reserved2[0x30];
} NfpTagInfoHost;
typedef struct {
    NfpDateHost last_write_date;
    uint16_t write_counter, version;
    uint32_t application_area_size;
    uint8_t reserved[0x34];
} NfpCommonInfoHost;
typedef struct {
    uint16_t game_character_id;
    uint8_t character_variant, series;
    uint16_t model_number;
    uint8_t figure_type, reserved[0x39];
} NfpModelInfoHost;
typedef struct {
    uint8_t mii[0x58];
    NfpDateHost first_write_date;
    char amiibo_name[41];
    uint8_t font_region, reserved[0x7a];
} NfpRegisterInfoHost;
_Static_assert(sizeof(NfpTagInfoHost) == 0x58, "NFP TagInfo ABI");
_Static_assert(sizeof(NfpCommonInfoHost) == 0x40, "NFP CommonInfo ABI");
_Static_assert(sizeof(NfpModelInfoHost) == 0x40, "NFP ModelInfo ABI");
_Static_assert(sizeof(NfpRegisterInfoHost) == 0x100, "NFP RegisterInfo ABI");
static pthread_mutex_t nfp_lock = PTHREAD_MUTEX_INITIALIZER;
static RuntimeVirtualAmiibo nfp_amiibo;
static int nfp_selected, nfp_detecting, nfp_scan_pending, nfp_status;
static int nfp_availability_pending, nfp_activate_pending, nfp_deactivate_pending;
static void *nfp_availability_event, *nfp_activate_event, *nfp_deactivate_event;
static const uint8_t nfp_virtual_handle[8] = {1};
static int nfp_valid_handle(const void *handle) {
    return handle && !memcmp(handle, nfp_virtual_handle, sizeof nfp_virtual_handle);
}
void runtime_nfp_set_virtual_amiibo(const RuntimeVirtualAmiibo *amiibo) {
    void *availability = NULL, *deactivate = NULL;
    pthread_mutex_lock(&nfp_lock);
    int was_found = nfp_status >= 2;
    nfp_amiibo = *amiibo;
    nfp_selected = 1;
    nfp_scan_pending = 0;
    nfp_status = nfp_detecting ? 1 : 0;
    nfp_activate_pending = 0;
    if (was_found) {
        deactivate = nfp_deactivate_event;
        nfp_deactivate_pending = deactivate == NULL;
    }
    availability = nfp_availability_event;
    nfp_availability_pending = availability == NULL;
    pthread_mutex_unlock(&nfp_lock);
    if (deactivate) hle_signal_system_event(deactivate);
    if (availability) hle_signal_system_event(availability);
}
void runtime_nfp_request_scan(void) {
    void *activate = NULL;
    pthread_mutex_lock(&nfp_lock);
    if (nfp_selected) {
        nfp_scan_pending = 1;
        if (nfp_detecting) {
            nfp_status = 2;
            nfp_scan_pending = 0;
            activate = nfp_activate_event;
            nfp_activate_pending = activate == NULL;
        }
    }
    pthread_mutex_unlock(&nfp_lock);
    if (activate) hle_signal_system_event(activate);
}
static unsigned nfp_list(void *handles, int *count, int max) {
    pthread_mutex_lock(&nfp_lock);
    int selected = nfp_selected;
    if (count) *count = selected;
    if (selected && handles && max > 0) memcpy(handles, nfp_virtual_handle, sizeof nfp_virtual_handle);
    pthread_mutex_unlock(&nfp_lock);
    return selected ? 0 : NFP_DEVICE_NOT_FOUND;
}
static unsigned nfp_attach_availability(void *event) {
    if (!event) runtime_fail("nfp availability event");
    hle_bind_system_event(event, 1);
    pthread_mutex_lock(&nfp_lock);
    nfp_availability_event = event;
    int signal = nfp_availability_pending || nfp_selected;
    nfp_availability_pending = 0;
    pthread_mutex_unlock(&nfp_lock);
    if (signal) hle_signal_system_event(event);
    return 0;
}
static int nfp_device_state(const void *handle) {
    pthread_mutex_lock(&nfp_lock);
    int state = nfp_selected && nfp_valid_handle(handle) ? nfp_status : 5;
    pthread_mutex_unlock(&nfp_lock);
    return state;
}
static unsigned nfp_attach_activate(void *event, const void *handle) {
    if (!event) runtime_fail("nfp activate event");
    hle_bind_system_event(event, 0);
    pthread_mutex_lock(&nfp_lock);
    if (!nfp_selected || !nfp_valid_handle(handle)) { pthread_mutex_unlock(&nfp_lock); return NFP_DEVICE_NOT_FOUND; }
    nfp_activate_event = event;
    int signal = nfp_activate_pending;
    nfp_activate_pending = 0;
    pthread_mutex_unlock(&nfp_lock);
    if (signal) hle_signal_system_event(event);
    return 0;
}
static unsigned nfp_attach_deactivate(void *event, const void *handle) {
    if (!event) runtime_fail("nfp deactivate event");
    hle_bind_system_event(event, 0);
    pthread_mutex_lock(&nfp_lock);
    if (!nfp_selected || !nfp_valid_handle(handle)) { pthread_mutex_unlock(&nfp_lock); return NFP_DEVICE_NOT_FOUND; }
    nfp_deactivate_event = event;
    int signal = nfp_deactivate_pending;
    nfp_deactivate_pending = 0;
    pthread_mutex_unlock(&nfp_lock);
    if (signal) hle_signal_system_event(event);
    return 0;
}
static unsigned nfp_start_detection(const void *handle) {
    void *activate = NULL;
    pthread_mutex_lock(&nfp_lock);
    if (!nfp_selected || !nfp_valid_handle(handle)) { pthread_mutex_unlock(&nfp_lock); return NFP_DEVICE_NOT_FOUND; }
    nfp_detecting = 1;
    nfp_status = 1;
    if (nfp_scan_pending) {
        nfp_scan_pending = 0;
        nfp_status = 2;
        activate = nfp_activate_event;
        nfp_activate_pending = activate == NULL;
    }
    pthread_mutex_unlock(&nfp_lock);
    if (activate) hle_signal_system_event(activate);
    return 0;
}
static unsigned nfp_stop_detection(const void *handle) {
    void *deactivate = NULL;
    pthread_mutex_lock(&nfp_lock);
    if (!nfp_selected || !nfp_valid_handle(handle)) { pthread_mutex_unlock(&nfp_lock); return NFP_DEVICE_NOT_FOUND; }
    int was_found = nfp_status >= 2;
    nfp_detecting = 0;
    nfp_status = 0;
    nfp_scan_pending = 0;
    if (was_found) {
        deactivate = nfp_deactivate_event;
        nfp_deactivate_pending = deactivate == NULL;
    }
    pthread_mutex_unlock(&nfp_lock);
    if (deactivate) hle_signal_system_event(deactivate);
    return 0;
}
static unsigned nfp_mount(const void *handle, int device_type, int mount_target) {
    (void)device_type; (void)mount_target;
    pthread_mutex_lock(&nfp_lock);
    if (!nfp_selected || !nfp_valid_handle(handle) || nfp_status < 2) { pthread_mutex_unlock(&nfp_lock); return NFP_DEVICE_NOT_FOUND; }
    nfp_status = 4;
    pthread_mutex_unlock(&nfp_lock);
    return 0;
}
static unsigned nfp_mount_default(const void *handle, int device_type) {
    return nfp_mount(handle, device_type, 1);
}
static unsigned nfp_unmount(const void *handle) {
    pthread_mutex_lock(&nfp_lock);
    if (!nfp_selected || !nfp_valid_handle(handle) || nfp_status != 4) { pthread_mutex_unlock(&nfp_lock); return NFP_DEVICE_NOT_FOUND; }
    nfp_status = 2;
    pthread_mutex_unlock(&nfp_lock);
    return 0;
}
static unsigned nfp_get_npad_id(uint32_t *out, const void *handle) {
    pthread_mutex_lock(&nfp_lock);
    int valid = nfp_selected && nfp_valid_handle(handle);
    pthread_mutex_unlock(&nfp_lock);
    if (!valid) return NFP_DEVICE_NOT_FOUND;
    *out = 0;
    return 0;
}
static unsigned nfp_get_tag_info(void *out, const void *handle) {
    RuntimeVirtualAmiibo amiibo;
    pthread_mutex_lock(&nfp_lock);
    int valid = nfp_selected && nfp_valid_handle(handle) && nfp_status >= 2;
    amiibo = nfp_amiibo;
    pthread_mutex_unlock(&nfp_lock);
    if (!valid) return NFP_DEVICE_NOT_FOUND;
    NfpTagInfoHost *info = out;
    memset(info, 0, sizeof *info);
    memcpy(info->uid, amiibo.uuid, sizeof info->uid);
    info->uid_length = amiibo.uid_length;
    info->protocol = 1;
    info->tag_type = 2;
    return 0;
}
static unsigned nfp_get_model_info(void *out, const void *handle) {
    RuntimeVirtualAmiibo amiibo;
    pthread_mutex_lock(&nfp_lock);
    int valid = nfp_selected && nfp_valid_handle(handle) && nfp_status == 4;
    amiibo = nfp_amiibo;
    pthread_mutex_unlock(&nfp_lock);
    if (!valid) return NFP_DEVICE_NOT_FOUND;
    NfpModelInfoHost *info = out;
    memset(info, 0, sizeof *info);
    info->game_character_id = amiibo.game_character_id;
    info->character_variant = amiibo.character_variant;
    info->series = amiibo.series;
    info->model_number = amiibo.model_number;
    info->figure_type = amiibo.figure_type;
    return 0;
}
static unsigned nfp_get_common_info(void *out, const void *handle) {
    RuntimeVirtualAmiibo amiibo;
    pthread_mutex_lock(&nfp_lock);
    int valid = nfp_selected && nfp_valid_handle(handle) && nfp_status == 4;
    amiibo = nfp_amiibo;
    pthread_mutex_unlock(&nfp_lock);
    if (!valid) return NFP_DEVICE_NOT_FOUND;
    NfpCommonInfoHost *info = out;
    memset(info, 0, sizeof *info);
    info->last_write_date = (NfpDateHost){amiibo.last_write_year, amiibo.last_write_month, amiibo.last_write_day};
    info->write_counter = amiibo.write_counter;
    info->version = amiibo.version;
    info->application_area_size = 0;
    return 0;
}
static unsigned nfp_open_application_area(const void *handle, uint32_t application_area_id) {
    (void)handle; (void)application_area_id;
    fprintf(stderr, "[botw] Amiibo application area is unavailable (tag payload is not decoded)\n");
    return NFP_DEVICE_NOT_FOUND;
}
static unsigned nfp_get_application_area(void *out, uint64_t *size, const void *handle, uint64_t offset) {
    (void)out; (void)handle; (void)offset;
    *size = 0;
    return NFP_DEVICE_NOT_FOUND;
}
static unsigned nfp_get_register_info(void *out, const void *handle) {
    RuntimeVirtualAmiibo amiibo;
    pthread_mutex_lock(&nfp_lock);
    int valid = nfp_selected && nfp_valid_handle(handle) && nfp_status == 4;
    amiibo = nfp_amiibo;
    pthread_mutex_unlock(&nfp_lock);
    if (!valid) return NFP_DEVICE_NOT_FOUND;
    NfpRegisterInfoHost *info = out;
    memset(info, 0, sizeof *info);
    info->first_write_date = (NfpDateHost){amiibo.first_write_year, amiibo.first_write_month, amiibo.first_write_day};
    memcpy(info->amiibo_name, amiibo.name, sizeof info->amiibo_name);
    return 0;
}
#else
void runtime_nfp_set_virtual_amiibo(const RuntimeVirtualAmiibo *amiibo) { (void)amiibo; }
void runtime_nfp_request_scan(void) {}
static unsigned nfp_list(void *handles, int *count, int max) { (void)handles; (void)max; if (count) *count = 0; return NFP_DEVICE_NOT_FOUND; }
static unsigned nfp_attach_availability(void *event) { if (!event) runtime_fail("nfp availability event"); hle_bind_system_event(event, 0); return 0; }
static int nfp_device_state(const void *h) { (void)h; return 0; }
static unsigned nfp_attach_activate(void *event, const void *handle) { (void)event; (void)handle; return NFP_DEVICE_NOT_FOUND; }
static unsigned nfp_attach_deactivate(void *event, const void *handle) { (void)event; (void)handle; return NFP_DEVICE_NOT_FOUND; }
static unsigned nfp_start_detection(const void *handle) { (void)handle; return NFP_DEVICE_NOT_FOUND; }
static unsigned nfp_stop_detection(const void *handle) { (void)handle; return NFP_DEVICE_NOT_FOUND; }
static unsigned nfp_mount(const void *handle, int type, int target) { (void)handle; (void)type; (void)target; return NFP_DEVICE_NOT_FOUND; }
static unsigned nfp_unmount(const void *handle) { (void)handle; return NFP_DEVICE_NOT_FOUND; }
static unsigned nfp_get_npad_id(uint32_t *out, const void *handle) { (void)out; (void)handle; return NFP_DEVICE_NOT_FOUND; }
static unsigned nfp_get_tag_info(void *out, const void *handle) { (void)out; (void)handle; return NFP_DEVICE_NOT_FOUND; }
static unsigned nfp_get_model_info(void *out, const void *handle) { (void)out; (void)handle; return NFP_DEVICE_NOT_FOUND; }
static unsigned nfp_get_common_info(void *out, const void *handle) { (void)out; (void)handle; return NFP_DEVICE_NOT_FOUND; }
static unsigned nfp_get_register_info(void *out, const void *handle) { (void)out; (void)handle; return NFP_DEVICE_NOT_FOUND; }
#endif

/* ---------- nn::err (nn::swkbd is in runtime/swkbd_host.c) ---------- */
static void show_error(uint32_t result) {
    fprintf(stderr, "[totk] game error dialog: %04u-%04u (result %#x)\n", 2000 + (result & 0x1ff), (result >> 9) & 0x1fff, result);
}

#ifdef GAME_BOTW
/* SDK 7 (Breath of the Wild 1.6.0, botw.md). Exit requests are handled by the window (the section brackets change nothing);
   video recording has no Mac counterpart; the DLC shop and the DLC-version error screen are console applets. */
static void exit_section(void) {}
static void enable_recording(void) {}
static void unacceptable_aoc_version(void) { fprintf(stderr, "[botw] the game reported a DLC version it cannot use\n"); }
static uint32_t show_aoc_shop(uint64_t application, const void *user) { (void)application; (void)user; fprintf(stderr, "[botw] eShop DLC page: not available\n"); return 0; }
#endif
void *runtime_applet_override(const char *name) {
    static const struct { const char *name; void *fn; } map[] = {
        {"_ZN2nn6applet23GetPreviousProgramIndexEv", previous_program_index},
        {"_ZN2nn6applet23GetAppletResourceUserIdEv", applet_resource_user_id},
        {"_ZN2nn2am23GetAppletResourceUserIdEv", applet_resource_user_id},
        {"_ZN2nn2oe21TryPopLaunchParameterEPmPvm", try_pop_launch_parameter},
        {"_ZN2nn2oe24GetExpectedVolumeBalanceEPfS1_", get_balance}, {"_ZN2nn2oe24SetExpectedVolumeBalanceEff", set_balance},
        {"_ZN2nn2oe25GetProgramTotalActiveTimeEv", total_active_time}, {"_ZN2nn2oe38SetUserInactivityDetectionTimeExtendedEb", inactivity_extended},
        {"_ZN2nn2oe44SetUserInactivityDetectionTimeExtendedUnsafeEb", inactivity_extended},
        {"_ZN2nn2oe17FinishStartupLogoEv", finish_startup_logo}, {"_ZN2nn2oe25TryPopNotificationMessageEPj", try_pop},
        {"_ZN2nn2oe22PopNotificationMessageEv", pop},
        {"_ZN2nn5prepo10PlayReport4SaveEv", report_save}, {"_ZN2nn5prepo10PlayReport4SaveERKNS_7account3UidE", report_save_uid},
        {"_ZN2nn5prepo28RequestImmediateTransmissionEv", immediate_transmission},
        {"_ZN2nn5prepo27AddInternetConnectionStatusEPNS0_10PlayReportEPKcS4_S4_", connection_status},
        {"_ZN2nn3nfp10InitializeEv", nfp_initialize}, {"_ZN2nn3nfp8FinalizeEv", nfp_finalize}, {"_ZN2nn3nfp8GetStateEv", nfp_get_state},
        {"_ZN2nn3nfp11ListDevicesEPNS0_12DeviceHandleEPii", nfp_list},
        {"_ZN2nn3nfp29AttachAvailabilityChangeEventEPNS_2os15SystemEventTypeE", nfp_attach_availability},
        {"_ZN2nn3nfp14GetDeviceStateERKNS0_12DeviceHandleE", nfp_device_state},
        {"_ZN2nn3nfp5MountERKNS0_12DeviceHandleENS0_9ModelTypeE", nfp_mount_default},
        {"_ZN2nn3nfp5MountERKNS0_12DeviceHandleENS0_9ModelTypeENS0_11MountTargetE", nfp_mount},
        {"_ZN2nn3nfp7UnmountERKNS0_12DeviceHandleE", nfp_unmount},
        {"_ZN2nn3nfp9GetNpadIdEPjRKNS0_12DeviceHandleE", nfp_get_npad_id},
        {"_ZN2nn3nfp19AttachActivateEventEPNS_2os15SystemEventTypeERKNS0_12DeviceHandleE", nfp_attach_activate},
        {"_ZN2nn3nfp21AttachDeactivateEventEPNS_2os15SystemEventTypeERKNS0_12DeviceHandleE", nfp_attach_deactivate},
        {"_ZN2nn3nfp14StartDetectionERKNS0_12DeviceHandleE", nfp_start_detection}, {"_ZN2nn3nfp13StopDetectionERKNS0_12DeviceHandleE", nfp_stop_detection},
        {"_ZN2nn3nfp10GetTagInfoEPNS0_7TagInfoERKNS0_12DeviceHandleE", nfp_get_tag_info},
        {"_ZN2nn3nfp12GetModelInfoEPNS0_9ModelInfoERKNS0_12DeviceHandleE", nfp_get_model_info},
        {"_ZN2nn3nfp13GetCommonInfoEPNS0_10CommonInfoERKNS0_12DeviceHandleE", nfp_get_common_info},
        {"_ZN2nn3nfp15GetRegisterInfoEPNS0_12RegisterInfoERKNS0_12DeviceHandleE", nfp_get_register_info},
#ifdef GAME_BOTW160
        {"_ZN2nn3nfp19OpenApplicationAreaERKNS0_12DeviceHandleEj", nfp_open_application_area},
        {"_ZN2nn3nfp18GetApplicationAreaEPvPmRKNS0_12DeviceHandleEm", nfp_get_application_area},
#endif
        {"_ZN2nn3err9ShowErrorENS_6ResultE", show_error},
#ifdef GAME_BOTW
        {"_ZN2nn2oe31EnterExitRequestHandlingSectionEv", exit_section}, {"_ZN2nn2oe31LeaveExitRequestHandlingSectionEv", exit_section},
        {"_ZN2nn2oe15EnableRecordingEv", enable_recording},
        {"_ZN2nn3err40ShowUnacceptableAddOnContentVersionErrorEv", unacceptable_aoc_version},
        {"_ZN2nn2ec24ShowShopAddOnContentListENS_13ApplicationIdERKNS_7account10UserHandleE", show_aoc_shop},
#endif
    };
    for (size_t i = 0; i < sizeof map / sizeof *map; i++) if (!strcmp(name, map[i].name)) return map[i].fn;
    return NULL;
}
