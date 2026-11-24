# Naming

One vocabulary for the app's own code. The UI's Chinese terms are the source:
**配置 / 节点 / 订阅 / 代理**. Code that means one of them uses the matching
English word; a concept does not keep a second name in another layer.

## Canonical terms

| Term | Meaning | UI word | Retired names |
| --- | --- | --- | --- |
| `Configuration` | A card in the Profiles screen: a set of nodes, local or remote. | 配置 | `ProxyGroup`, `GroupRow`, B-box `Profile` |
| `Node` | One proxy entry inside a configuration. | 节点 | `ProxyEntity`, `ProfileRow`, `ProxyNode` |
| `Subscription` | A remote configuration (`Configuration` whose URL is set); a mode of a configuration, not another type. | 订阅 | remote profile, sub |
| `Proxy` | The Proxies screen and its presentation (cards, list, settings). No data type of its own. | 代理 | — |
| `Outbound` | The protocol payload of one node (sing-box `outbound`). Owned by the kernel model. | — | — |
| `RouteProfile` | A routing document profile. Unrelated to a configuration. | 路由配置 | — |

## Boundaries that keep their names

These are contracts, not app vocabulary. Renaming them is a wire/format break,
so they stay:

- **Document format**: `profiles.json`, its `profiles` / `groups` arrays, `nextProfileId`, `nextGroupId`, `gid`.
- **Bridge protocol**: the `profiles.platform` op name and every payload key (`id`, `groupId`, `profileId`, `nodeId`, `selectedProfileId`, `single`, `remote`, …); event type `profiles`.
- **Settings keys**: `profileId`, `profileCurrent`, `profilesMode`, `proxySelected`, `lastProfileId` and the rest of the persisted keys.
- **FFI / Go**: `throne_*` exports, generated bindings, `live_exports.txt`, the kernel's `profiles_doc.go` JSON.
- **Upstream Room columns**: `groups`, `profiles`, `user_order`, `display_order` (the legacy reader only).
- **l10n keys**: the English source strings are UI labels, not identifiers.
- **Route profiles**: every `RouteProfile*` / `routeProfiles` name stays; it is a different concept.

At a boundary, map explicitly in one place (a bridge wire function or a JSON
codec) instead of naming the app type after the wire key.

## Migration

The rename is staged so each step compiles and has its own tests:

1. Dart UI: `ProfileCard` → `ConfigurationCard`, `ProfileForm` → `ConfigurationForm`, `ProfilesPage` → `ConfigurationsPage`, `ProfileDetailsPage` → `ConfigurationDetailsPage`, `ProfileEditor` → `ConfigurationEditor`, `ProfileOrderPage` → `ConfigurationOrderPage`, `ProfileQuota*` → `SubscriptionQuota*`; files and imports follow.
2. Dart data/bridge: `ProfileRow` → `NodeRow`, `GroupRow` → `ConfigurationRow`, `ProfileStore` → `ConfigurationStore`, `BoxController.profiles`/`selectedProfileId` → `configurations`/`selectedConfigurationId`, `profileXxx` bridge helpers → `configurationXxx` (wire keys untouched).
3. Kotlin domain: `ProxyGroup` → `Configuration`, `ProxyEntity` → `Node`, `ProfileManager` → `NodeManager`, `GroupRepo` → `ConfigurationRepo`, `DataStore.selectedProxy`/`currentProfile` → `selectedNodeId`/`currentNodeId`.
4. Kotlin bridge/tests/docs: `BboxProfiles`/`BboxProfileDuty` and the test names follow; audits and this document are updated together.
