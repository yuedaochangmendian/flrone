import '../box.dart';

/// The preference holding the node each configuration was left on.
///
/// The native side keeps one global selected proxy, so a configuration switch
/// lands on the target group's first member and the group forgets its previous
/// node. The UI remembers the choice here and replays it when that
/// configuration becomes active again.
const proxySelectedKey = 'proxySelected';

/// How many configurations keep a remembered node; the oldest entry is dropped.
const _memoryLimit = 64;

/// The memory key of one configuration (the group id is its identity).
String proxySelectionKey(int groupId) => 'local:$groupId';

/// Records [nodeId] as the node [groupId] was left on.
///
/// Every explicit selection path calls this — the proxies list and the
/// single-node page — so the memory follows the user's last choice instead of
/// only what one screen happened to see. Without the node page's write, a node
/// picked there was replayed over by the proxies page's older entry the next
/// time that configuration became active.
Future<void> rememberProxySelection(
  BoxController box, {
  required int groupId,
  required String groupTag,
  required int? nodeId,
  required String nodeTag,
}) async {
  if (groupId <= 0) return;
  final saved = json(box.preferences[proxySelectedKey]);
  saved[proxySelectionKey(groupId)] = {
    'group': groupTag,
    'id': nodeId,
    'tag': nodeTag,
  };
  while (saved.length > _memoryLimit) {
    saved.remove(saved.keys.first);
  }
  await box.setPreference(proxySelectedKey, saved);
}
