// Clash YAML detection hook for the subscription-body importer.
//
// This file is the ONLY bridge between profileImportBody and the Clash YAML
// converter. It deliberately does NOT implement Clash-to-stored conversion:
// that is the other agent's slice (profile_clash_yaml.go parses YAML to a
// generic tree; the stored converter has not landed yet).
//
// Wiring instruction for that slice: replace the body of
// `profileImportClashBody` below with a call to the new converter. Keep the
// function name and signature -- profile_import_body.go calls this function
// when a Clash YAML subscription is detected. Do not add a second function
// with the same name (Go has no overloads); edit this one in place.
package mobile

// profileImportClashBody refuses Clash subscriptions until the Clash-to-stored
// converter is wired. Refusing whole-body keeps the no-partial-results contract.
func profileImportClashBody(_ string) ([]profileImportedNode, error) {
	return nil, profileUnsupported("Clash YAML subscription bodies are not wired into profileImport yet (Clash-to-stored converter pending)")
}
