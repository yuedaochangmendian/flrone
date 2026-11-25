# Routing Rules Specification

## Purpose

Defines management and application of routing rules: how the user defines domain/IP-based
traffic rules, how one global rule table is applied to every connection, and how that table
shapes per-connection routing decisions.

## Requirements

### Requirement: Single global rule table
The app SHALL keep exactly one ordered rule table, stored as the kernel-owned
`documents/global_route_rules.json`. There are no routing profiles, no per-configuration
rule lists and no current-profile selection: the same table is the routing input for
every build. Go is the only ongoing writer; Kotlin and Dart keep read-only views.

#### Scenario: One table for every configuration
- **WHEN** the user opens the Routing screen
- **THEN** the app shows the single global rule table, and every configuration uses those
  rules in the same order

#### Scenario: Upgrade from a profile-based install
- **WHEN** an existing install has `route_profiles.json` / `route_rules.json` and no
  `global_route_rules.json`
- **THEN** the app migrates the old rules into the single table once, without dropping
  user rules, and never reads the old documents again

### Requirement: Routing rule definition
The app SHALL let the user create routing rules that match traffic by domain lists, IP CIDR
lists, ports, protocols, network types and rule-set references, and assign each matched
rule an outbound action (proxy, direct, block) chosen from available outbounds.

#### Scenario: Domain rule to direct
- **WHEN** the user adds a rule matching a domain to Direct and starts the VPN
- **THEN** traffic to that domain bypasses the proxy

### Requirement: Rule ordering
Routing decisions SHALL evaluate rules in the user-defined order and apply the first
matching rule. The stored `rule_order` is the visible order.

#### Scenario: Overlapping rules
- **WHEN** two rules both match a destination but assign different actions
- **THEN** the earlier rule in the list determines the action

#### Scenario: Reorder persists
- **WHEN** the user drags a rule to a new position
- **THEN** the stored order matches the visible order and the router evaluates it that way

### Requirement: Rule set references
Routing rules SHALL be able to reference external rule sets, and the app SHALL report
unresolvable rule set references as configuration errors rather than silently ignoring
them.

#### Scenario: Missing rule set
- **WHEN** a rule references a rule set that cannot be resolved at connection start
- **THEN** the app surfaces a routing configuration error

### Requirement: Rule editing surface
The single table SHALL be editable on the Routing screen with search, drag ordering,
bulk text add, delete with undo, per-rule disable and JSON fragment import. A single-rule
editor presents the rule's fields; saving replaces the whole table atomically.

#### Scenario: Atomic save
- **WHEN** the user saves the rule table
- **THEN** the kernel writes the whole table through one versioned, atomic document write

### Requirement: Backup compatibility
A backup produced by an older build (with `route_profiles` / `route_rules` / `global_route_rules`
tables) SHALL still restore: the old per-profile rules are merged into the single global
table. New backups SHALL carry the single table only.
