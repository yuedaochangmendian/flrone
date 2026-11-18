// The entry point for the plain c-shared build.
//
// Go requires `-buildmode=c-shared` to build exactly one main package, while
// the bridge lives in the library package `ThroneCore/mobile`. This wrapper is
// the whole c-shared build: importing the mobile package pulls in its //export
// functions and the callback/runtime glue; main itself does nothing.
//
// Used by buildScript/build-cshared.sh. The gomobile AAR stays the shipped path
// until the Kotlin host has moved off io.throneproj.mobile.*; this is the
// foundation for that migration, not a switch.
package main

import _ "ThroneCore/mobile"

func main() {}
