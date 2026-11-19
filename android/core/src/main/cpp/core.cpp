// The JNI shim for the self-owned kernel bridge (bettbox android/core shape).
//
// JNI_OnLoad fills throne_callbacks_t with thunks that reach Kotlin: the tun
// token handed to throne_start_tun is a TunInterface global ref (protect /
// resolverProcess); everything else goes to the CorePlatform registered through
// Core.setPlatform. The Kotlin->Go direction (startTun, interface-monitor
// reports) calls the throne_* C ABI exported by the Go shared library directly.

#ifdef LIBCORE
#include <jni.h>
#include <android/log.h>
#include <cstring>
#include <cstdlib>
#include "jni_helper.h"
#include "bridge_symbols.h"

static jobject g_platform;   // CorePlatform global ref
static jmethodID m_platform_request;
static jmethodID m_tun_protect;
static jmethodID m_tun_resolver;

// --- tun-scoped thunks (the TunInterface token) -----------------------------

static void cb_protect(void *tun, int32_t fd) {
    if (tun == nullptr) return;
    ATTACH_JNI();
    env->CallVoidMethod(static_cast<jobject>(tun), m_tun_protect, fd);
    jni_catch_exception(env);
}

static const char *cb_resolver_process(void *tun, int32_t protocol,
                                       const char *source, const char *target,
                                       int32_t uid) {
    if (tun == nullptr) return strdup("");
    ATTACH_JNI();
    if (env->PushLocalFrame(8) < 0) return strdup("");
    const auto src_str = new_string(source != nullptr ? source : "");
    const auto dst_str = new_string(target != nullptr ? target : "");
    const auto result = reinterpret_cast<jstring>(env->CallObjectMethod(
        static_cast<jobject>(tun), m_tun_resolver, protocol, src_str, dst_str, uid));
    jni_catch_exception(env);
    const auto out = get_string(result);
    env->PopLocalFrame(nullptr);
    return out;
}

static void cb_release_object(void *obj) {
    if (obj == nullptr) return;
    ATTACH_JNI();
    del_global(static_cast<jobject>(obj));
}

// --- platform-wide thunk (the CorePlatform singleton) -----------------------

// The single JSON duty facade: Kotlin takes (method, payload JSON) and returns
// a JSON string on the Go-owned thread; the Go caller frees it via goStr. Keep
// the result's local ref deleted: this runs on attached Go threads whose local
// table lives for the whole thread.
static const char *cb_platform_request(const char *method, const char *payload_json) {
    if (g_platform == nullptr) return strdup("");
    ATTACH_JNI();
    if (env->PushLocalFrame(4) < 0) return strdup("");
    jvalue args[2];
    args[0].l = new_string(method != nullptr ? method : "");
    args[1].l = new_string(payload_json != nullptr ? payload_json : "{}");
    const auto result = reinterpret_cast<jstring>(env->CallObjectMethodA(
        g_platform, m_platform_request, args));
    jni_catch_exception(env);
    const auto out = get_string(result);
    if (result != nullptr) env->DeleteLocalRef(result);
    env->PopLocalFrame(nullptr);
    return out;
}

// --- Kotlin -> Go ------------------------------------------------------------

extern "C"
JNIEXPORT void JNICALL
Java_io_flrone_core_Core_startTun(JNIEnv *env, jobject, const jint fd, jobject tun) {
    const auto token = new_global(tun);
    throne_start_tun(fd, token);
}

extern "C"
JNIEXPORT void JNICALL
Java_io_flrone_core_Core_stopTun(JNIEnv *) {
    throne_stop_tun();
}

extern "C"
JNIEXPORT void JNICALL
Java_io_flrone_core_Core_setPlatform(JNIEnv *env, jobject, jobject platform) {
    if (g_platform != nullptr) {
        del_global(g_platform);
    }
    g_platform = new_global(platform);
}

extern "C"
JNIEXPORT void JNICALL
Java_io_flrone_core_Core_updateDefaultInterface(JNIEnv *env, jobject,
                                                     const jlong listener,
                                                     jstring name, const jint index,
                                                     const jboolean is_expensive,
                                                     const jboolean is_constrained) {
    scoped_string n = get_string(name);
    throne_InterfaceUpdateListener_updateDefaultInterface(
        listener, n, index, is_expensive ? 1 : 0, is_constrained ? 1 : 0);
}

extern "C"
JNIEXPORT jstring JNICALL
Java_io_flrone_core_Core_tunSpecJson(JNIEnv *env, jobject, const jlong handle) {
    const auto json = throne_TunOptions_toJSON(handle);
    const char *text = json != nullptr ? json : "";
    if (text[0] == '\0') {
        // An empty spec used to surface only as a JSONException in VpnService,
        // which hid whether the handle was unknown or the marshaling panicked.
        const auto last = throne_last_error();
        __android_log_print(ANDROID_LOG_WARN, "ThroneTun",
                            "tunSpecJson(handle=%lld) is empty; last_error=%s",
                            static_cast<long long>(handle),
                            last != nullptr ? last : "(none)");
        if (last != nullptr) throne_free(const_cast<char *>(last));
    }
    const auto out = env->NewStringUTF(text);
    if (json != nullptr) throne_free(const_cast<char *>(json));
    return out;
}

extern "C"
JNIEXPORT jstring JNICALL
Java_io_flrone_core_Core_runAction(JNIEnv *env, jobject, jstring action) {
    scoped_string input = get_string(action);
    const auto result = throne_run_action(input);
    const auto out = env->NewStringUTF(result != nullptr ? result : "");
    if (result != nullptr) throne_free(const_cast<char *>(result));
    return out;
}

extern "C"
JNIEXPORT jstring JNICALL
Java_io_flrone_core_Core_hostCall(JNIEnv *env, jobject, jstring request) {
    scoped_string input = get_string(request);
    const auto result = throne_host_call(input);
    const auto out = env->NewStringUTF(result != nullptr ? result : "");
    if (result != nullptr) throne_free(const_cast<char *>(result));
    return out;
}

extern "C"
JNIEXPORT void JNICALL
Java_io_flrone_core_Core_exchangeSuccess(JNIEnv *env, jobject, const jlong handle, jstring result) {
    scoped_string r = get_string(result);
    throne_ExchangeContext_success(handle, r);
}

extern "C"
JNIEXPORT void JNICALL
Java_io_flrone_core_Core_exchangeRawSuccess(JNIEnv *env, jobject, const jlong handle, jbyteArray result) {
    const jsize len = result != nullptr ? env->GetArrayLength(result) : 0;
    jbyte *bytes = len > 0 ? env->GetByteArrayElements(result, nullptr) : nullptr;
    throne_ExchangeContext_rawSuccess(handle, reinterpret_cast<uint8_t *>(bytes), len);
    if (bytes != nullptr) env->ReleaseByteArrayElements(result, bytes, JNI_ABORT);
}

extern "C"
JNIEXPORT void JNICALL
Java_io_flrone_core_Core_exchangeErrorCode(JNIEnv *, jobject, const jlong handle, const jint code) {
    throne_ExchangeContext_errorCode(handle, code);
}

extern "C"
JNIEXPORT void JNICALL
Java_io_flrone_core_Core_exchangeErrnoCode(JNIEnv *, jobject, const jlong handle, const jint code) {
    throne_ExchangeContext_errnoCode(handle, code);
}

extern "C"
JNIEXPORT void JNICALL
Java_io_flrone_core_Core_exchangeOnCancel(JNIEnv *, jobject, const jlong handle) {
    throne_ExchangeContext_onCancel(handle);
}

// --- registration ------------------------------------------------------------

extern "C"
JNIEXPORT jint JNICALL
JNI_OnLoad(JavaVM *vm, void *) {
    JNIEnv *env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    initialize_jni(vm, env);

    const auto c_tun = find_class("io/flrone/core/TunInterface");
    m_tun_protect = find_method(c_tun, "protect", "(I)V");
    m_tun_resolver = find_method(c_tun, "resolverProcess",
                                 "(ILjava/lang/String;Ljava/lang/String;I)Ljava/lang/String;");

    const auto c_platform = find_class("io/flrone/core/CorePlatform");
    m_platform_request = find_method(c_platform, "platformRequest",
                                     "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");

    throne_callbacks_t table{};
    table.protect = cb_protect;
    table.resolver_process = cb_resolver_process;
    table.release_object = cb_release_object;
    table.platform_request = cb_platform_request;
    throne_register_callbacks(&table);
    return JNI_VERSION_1_6;
}
#endif
