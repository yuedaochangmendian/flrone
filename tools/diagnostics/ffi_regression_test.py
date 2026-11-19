#!/usr/bin/env python3
"""Regression tests for the FFI hardening (2026-11-04).

These are static contract tests: they run on any CI image without Go, the NDK
or an Android device, and fail the moment one of the runtime fixes is regressed
by a regenerated file or an over-eager refactor. Architecture-level symbol
equality is covered by symbol_audit.py; this file covers *behavioural intent*.

Run:  python3 tools/diagnostics/ffi_regression_test.py
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "buildScript" / "core-patch" / "core" / "mobile"
CORE = ROOT / "flutter" / "lib" / "core"
LIVE = ROOT / "tools" / "bindgen" / "live_exports.txt"


def load_live_exports() -> set[str]:
    syms = set()
    for line in LIVE.read_text(encoding="utf-8").splitlines():
        code = line.split("#", 1)[0].strip()
        if code:
            syms.add(code)
    return syms


def export_body(source: str, name: str) -> str:
    match = re.search(rf"^//export {name}\s*$\n^func {name}\(.*?^\}}", source, re.S | re.M)
    if not match:
        raise AssertionError(f"missing export body: {name}")
    return match.group(0)


class FfiHardeningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.calls = (PATCH / "bridge_calls.go").read_text(encoding="utf-8")
        cls.runtime = (PATCH / "bridge_runtime.go").read_text(encoding="utf-8")
        cls.dartbridge = (PATCH / "dartbridge.go").read_text(encoding="utf-8")
        cls.service = (CORE / "kernel_service.dart").read_text(encoding="utf-8")
        cls.worker = (CORE / "kernel_worker.dart").read_text(encoding="utf-8")
        cls.box = (ROOT / "flutter" / "lib" / "box.dart").read_text(encoding="utf-8")

    def test_pinned_exports_are_on_the_live_surface(self) -> None:
        """Every throne_* symbol this file pins must exist in live_exports.txt.

        A regression test that silently pins a pruned export is worse than no
        test: it passes against a file the app no longer links. Keep the pins
        honest by checking them against the same whitelist symbol_audit uses.
        """
        live = load_live_exports()
        pinned = {
            "throne_handle_stats", "throne_Instance_close", "throne_handle_release",
            "throne_status_snapshot", "throne_Instance_alive", "throne_Instance_start",
            "throne_TunOptions_toJSON", "throne_start_tun", "throne_register_callbacks",
            "throne_run_action", "throne_host_call", "throne_free",
        }
        self.assertLessEqual(pinned, live,
                             f"pinned exports missing from the whitelist: {sorted(pinned - live)}")
        for name, source in (("calls", self.calls), ("runtime", self.runtime)):
            exports = set(re.findall(r"^//export (throne_\w+)", source, re.M))
            self.assertLessEqual(exports, live,
                                 f"{name} exports missing from the whitelist: {sorted(exports - live)}")

    def test_panics_cannot_cross_cgo(self) -> None:
        for name, source in (("calls", self.calls), ("runtime", self.runtime),
                             ("dartbridge", self.dartbridge)):
            self.assertNotRegex(source, r"\bpanic\(", f"{name} can still abort the process")
        self.assertIn("func guardExport(name string)", self.calls)
        self.assertIn("func initDartApi(api unsafe.Pointer) error", self.dartbridge)

    def test_handle_table_is_observable_and_releasable(self) -> None:
        self.assertIn("handleCreated++", self.calls)
        self.assertIn("handleReleased++", self.calls)
        self.assertIn("handleWarnThreshold", self.calls)
        self.assertIn("throne_handle_stats", self.calls)
        close = export_body(self.calls, "throne_Instance_close")
        self.assertIn("throne_handle_release(handle)", close,
                      "closing an Instance must drop its handle")

    def test_status_snapshot_is_one_crossing_without_a_handle(self) -> None:
        snap = export_body(self.runtime, "throne_status_snapshot")
        self.assertNotIn("marshal_handle", snap)
        for field in ("memory", "goroutines", "connectionsIn", "connectionsOut",
                      "uplink", "downlink", "uplinkTotal", "downlinkTotal"):
            self.assertIn(f'"{field}"', snap)
        self.assertIn('sendEvent("status", snap)', snap,
                      "the UI is driven by a pushed event, not by a poll result")

    def test_ui_isolate_never_opens_the_ffi_library(self) -> None:
        # The service engine owns the FFI in its main isolate (Bettbox-style).
        # The UI side must still never touch DynamicLibrary; the service-side
        # worker opens the library directly, with no second isolate or port hop.
        self.assertNotIn("Isolate.run", self.service)
        self.assertNotIn("DynamicLibrary.open", self.service)
        self.assertIn("KernelWorker.spawn()", self.service)
        self.assertNotIn("dart:isolate", self.worker,
                         "the in-process worker must not depend on dart:isolate")
        self.assertNotIn("Isolate.spawn", self.worker,
                         "the worker must not spin up a second isolate")
        self.assertNotIn("ReceivePort", self.worker)
        self.assertNotIn("SendPort", self.worker)
        self.assertIn("DynamicLibrary.open('libthrone.so')", self.worker,
                      "the service engine's worker must hold the FFI directly")
        self.assertIn("KernelHeartbeatPolicy", self.worker)

    def test_temporary_wrappers_are_released_explicitly(self) -> None:
        for call in ("options.release()", "current.release()", "iterator?.release()",
                     "identity?.release()", "request.release()"):
            self.assertIn(call, self.worker, f"missing explicit release: {call}")

    def test_startup_failure_is_visible_to_the_ui(self) -> None:
        # The service-engine split renamed the driver attach from
        # `kernel.initialize()` to `kernel.connect()`; the invariant is the same:
        # the attach sits in a try whose failure reaches startupError.
        init = self.box.index("await kernel.connect();")
        catch = self.box.find("startupError = describe(error);", init)
        self.assertGreater(catch, init,
                           "kernel.connect() must be inside a try that sets startupError")

    def test_lost_core_is_detected_and_recovered(self) -> None:
        self.assertIn("'type': 'lost'", self.worker)
        self.assertIn("throneStatusSnapshot(ffi, current.handle)", self.worker)
        # A status read that fails is not a dead core: the cheap liveness probe
        # must be asked before a miss is counted, or a busy box gets restarted.
        self.assertIn("throne_Instance_alive(current.handle)", self.worker)
        self.assertIn("_recoverOnce()", self.service)
        self.assertIn("the kernel stopped responding", self.service)

    def test_worker_covers_every_kernel_operation(self) -> None:
        # With the command enum gone, the contract is now the concrete methods
        # implemented by the in-process worker (they back the KernelWorker
        # interface the service engine drives). Keep every operation pinned.
        for method in ("createInstance", "start", "stop", "setHeartbeat",
                       "needWifiState", "updateWifiState", "updateRuleSets",
                       "warpRegister", "dispose"):
            self.assertIsNotNone(
                re.search(rf"^\s*Future<.*>\s+{method}\s*\(", self.worker, re.M),
                f"worker is missing the {method} operation",
            )
        self.assertNotIn("KernelCommand", self.worker,
                         "the command enum must not survive the no-worker refactor")

    def test_ffi_path_registers_vpn_service_before_open_tun(self) -> None:
        """The FFI start skips startProcesses(), so openTun would see a null service."""
        base = (ROOT / "app" / "src" / "main" / "java" / "io" / "nekohasekai" /
                "sagernet" / "bg" / "BaseService.kt").read_text(encoding="utf-8")
        platform = (ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" /
                    "bridge" / "BboxCorePlatform.kt").read_text(encoding="utf-8")
        self.assertIn("DataStore.vpnService ?: run", platform,
                      "openTun must still depend on the registered VpnService")
        self.assertIn("openTun without a live VpnService", platform,
                      "a missing VpnService must be logged instead of failing silently")
        start = base.index("fun startProxy()")
        # The service is FFI-only now (BboxKernel.ffiMode is always true and no longer
        # branches here); the boundary that still matters is the job that lets the core
        # ask for the tun.
        ffi_return = base.index("data.connectingJob = CoroutineScope", start)
        self.assertIn("if (this is VpnService) DataStore.vpnService = this",
                      base[start:ffi_return],
                      "startProxy must register the VpnService before the FFI early return")

    def test_service_start_waits_for_the_vpn_service(self) -> None:
        """`service.start` only posted an intent, so Dart's FFI start raced the service.

        The channel answer must come after the live VpnService exists; otherwise
        the core's openTun runs first and the start dies with
        "configure tun interface: bridge: platform callback failed".
        """
        bridge = (ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" /
                  "flutter" / "ThroneBoxBridge.kt").read_text(encoding="utf-8")
        actions = (ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" /
                   "flutter" / "KernelServiceActions.kt").read_text(encoding="utf-8")
        self.assertIn('"service.start" -> result.respond {', bridge,
                      "service.start must answer only after the service is ready")
        self.assertIn("KernelServiceActions.startServiceAndAwaitTun()", bridge,
                      "the bridge must delegate to the shared wait, not answer early")
        self.assertNotIn('"service.start" -> {\n                    if (!DataStore.serviceState.canStop) SagerNet.startService()\n                    result.success(null)\n                }',
                         bridge,
                         "service.start must not answer before the service exists")
        # The wait itself moved into KernelServiceActions (shared by the UI and
        # service-engine bridges); the behaviour it pins is unchanged.
        wait = actions.index("suspend fun startServiceAndAwaitTun(")
        body = actions[wait:actions.index("\n    }", wait)]
        self.assertIn("SagerNet.startService(flags)", body)
        self.assertIn("while (DataStore.vpnService == null)", body)
        self.assertIn("SERVICE_READY_TIMEOUT_MS", body,
                      "the wait needs a timeout so a broken start fails loudly")
        self.assertIn("Key.MODE_VPN", body,
                      "the tun only exists in VPN mode; proxy mode must not wait")


    def test_tun_spec_json_tolerates_a_disabled_http_proxy(self) -> None:
        """GetHTTPProxyServer() dereferences the nil TunPlatformOptions.HTTPProxy.

        Calling the proxy getters unconditionally panicked inside
        throne_TunOptions_toJSON, so the spec reached VpnService empty and every
        start died with "configure tun interface: bridge: platform callback
        failed" (really: JSONException "End of input at character 0").
        """
        runtime = (ROOT / "buildScript" / "core-patch" / "core" / "mobile" /
                   "bridge_runtime.go").read_text(encoding="utf-8")
        self.assertIn("if httpProxy := o.IsHTTPProxyEnabled(); httpProxy {", runtime,
                      "the HTTP proxy getters must stay behind the enabled guard")
        self.assertNotIn('dto["httpProxyServer"] = o.GetHTTPProxyServer()\n\tdto["httpProxyServerPort"]',
                         runtime,
                         "unguarded GetHTTPProxyServer() panics when the option is off")
        # The guarded branch must still report the full spec when it is on.
        for key in ('dto["httpProxyEnabled"] = true', 'dto["httpProxyServer"] = ""',
                    'dto["httpProxyServerPort"] = int32(0)', 'dto["httpProxyBypassDomain"] = []string{}'):
            self.assertIn(key, runtime, f"missing proxy field default: {key}")

    def test_ip_probe_uses_the_live_core(self) -> None:
        # P5: the typed throne_Mobile_startIPTest export (which used to call
        # startIPTestLive) is off the live surface -- tests now run through the
        # action/host-call bus. The live-core implementation itself is retained
        # in bridge_runtime.go, so assert the behaviour there rather than at the
        # pruned export's call site. All the substantive checks below are
        # unchanged: the IP probe must measure the running core, not a new box.
        self.assertIn("func startIPTestLive(", self.runtime,
                      "the live-core IP probe implementation must survive pruning")
        self.assertIn("probe.LiveInstance(probe.TestContext())", self.runtime)
        self.assertIn("prepareTestEnv(current, true, platform, request)", self.runtime)

    def test_url_probe_uses_the_live_core_for_the_running_exit(self) -> None:
        # P5: same as above -- the pruned typed export called startURLTestLive;
        # the live-core URL-probe logic remains in bridge_runtime.go.
        self.assertIn("func startURLTestLive(", self.runtime,
                      "the live-core URL probe implementation must survive pruning")
        self.assertIn("request.TestCurrent", self.runtime)
        self.assertIn("lastInstance.inst", self.runtime)
        self.assertIn("probe.BatchURLTest(testCtx, env.Box, env.Tags, request.URL, "
                      "int(request.MaxConcurrency), false, timeout)", self.runtime,
                      "a proxy probe must issue one request like FlClash, not two timed requests")
        self.assertIn('probe.BatchIPTest(testCtx, env.Box, env.Tags, int(request.MaxConcurrency), '
                      'false, timeout, "")', self.runtime,
                      "the IP probe follows BatchIPTest's provider argument")
        commands = (ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" / "bridge" /
                    "BboxCommands.kt").read_text(encoding="utf-8")
        self.assertIn("persistCurrentResult = live", commands)
        self.assertIn("https://www.gstatic.com/generate_204", commands)
        self.assertIn("maxOf(DataStore.urlTestTimeoutMs, FLCLASH_TEST_TIMEOUT_MS)", commands)

    def test_tun_spec_json_marshals_every_builder_field(self) -> None:
        """VpnService.Builder needs the same fields the old gobind path fed it."""
        runtime = (ROOT / "buildScript" / "core-patch" / "core" / "mobile" /
                   "bridge_runtime.go").read_text(encoding="utf-8")
        start = runtime.index("func throne_TunOptions_toJSON")
        body = runtime[start:runtime.index("var _ = unsafe.Pointer(nil)", start)]
        for field in ("mtu", "autoRoute", "inet4Address", "inet6Address", "inet4RouteAddress",
                      "inet6RouteAddress", "inet4RouteExcludeAddress", "inet6RouteExcludeAddress",
                      "inet4RouteRange", "inet6RouteRange", "includePackage", "excludePackage",
                      "dnsMode", "dnsServerAddress"):
            self.assertIn(f'"{field}"', body, f"tun spec is missing {field}")


    def test_stop_releases_the_cached_tun_descriptor(self) -> None:
        """The kernel caches the fd from throne_start_tun and reuses it.

        Nothing called Core.stopTun(), so a stop left the cached descriptor behind
        and the next start skipped establishing the interface: no tun0 and no VPN
        network while the dashboard still said Running.
        """
        vpn = (ROOT / "app" / "src" / "main" / "java" / "io" / "nekohasekai" /
               "sagernet" / "bg" / "VpnService.kt").read_text(encoding="utf-8")
        kill = vpn.index("override suspend fun killProcesses()")
        body = vpn[kill:vpn.index("override fun onBind", kill)]
        self.assertIn("Core.stopTun()", body,
                      "killProcesses must drop the cached tun descriptor")
        destroy = vpn.index("override fun onDestroy()")
        self.assertIn("Core.stopTun()", vpn[destroy:destroy + 500],
                      "a service torn down without killProcesses must drop it too")


    def test_set_mode_refreshes_the_pushed_dashboard(self) -> None:
        """The FFI mode switch persisted the mode but never refreshed the UI state.

        BboxBridge caches dashboard.mode and the bridge re-publishes that cache on
        every change. BboxKernel.setMode only wrote the store, so the next push
        carried the previous mode, Dart applied it and the chips snapped back: the
        switch looked dead even though the store already held the new value.
        """
        kernel = (ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" /
                  "bridge" / "BboxKernel.kt").read_text(encoding="utf-8")
        start = kernel.index("fun setMode(mode: String)")
        body = kernel[start:kernel.index("\n    }", start)]
        self.assertIn("BboxMode.set(", body, "the mode must reach the store")
        self.assertIn("BboxBridge.scheduleRefresh(immediate = true)", body,
                      "without a refresh the cached dashboard keeps the old mode")

    def test_dashboard_wire_reads_the_stored_mode(self) -> None:
        """The wire must never echo a cached mode back to Dart.

        Even with the refresh above, a push can race the catalog reload. Reading the
        store makes every emission self-consistent, so the highlight cannot revert.
        """
        bridge = (ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" /
                  "flutter" / "ThroneBoxBridge.kt").read_text(encoding="utf-8")
        start = bridge.index("private fun dashboardWire(")
        body = bridge[start:bridge.index("private fun profilesWire", start)]
        self.assertIn('"mode" to BboxMode.get().id', body,
                      "dashboardWire must read the stored mode, not dashboard.mode")
        self.assertNotIn('"mode" to dashboard.mode', body)
        self.assertIn("import io.flrone.bridge.BboxMode", bridge)


if __name__ == "__main__":
    unittest.main(verbosity=2)
