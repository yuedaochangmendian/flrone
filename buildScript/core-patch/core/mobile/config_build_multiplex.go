// Multiplex for the Stage-2 outbound builder.
//
// Multiplex.parseFromJson keeps the Keep Default / On / Off tri-state (only a
// stored `enabled` leaves Keep Default) and Multiplex.build emits the global
// preset, or the profile's own settings under Custom, exactly like
// multiplex.cpp:140-241.
package mobile

type configBrutalParams struct {
	enabled  bool
	upMbps   int
	downMbps int
}

type configMultiplexParams struct {
	enabled        bool
	unspecified    bool
	protocol       string
	maxConnections int
	minStreams     int
	maxStreams     int
	padding        bool
	brutal         configBrutalParams
}

// configMultiplexDefault is a fresh Multiplex(): Keep Default.
func configMultiplexDefault() configMultiplexParams {
	return configMultiplexParams{unspecified: true}
}

// configMultiplexParse is Multiplex.parseFromJson.
func configMultiplexParse(object map[string]any) (configMultiplexParams, error) {
	multiplex := configMultiplexDefault()
	if object == nil || len(object) == 0 {
		return multiplex, nil
	}
	allowed := configKeysAllowed("enabled", "protocol", "max_connections", "min_streams", "max_streams", "padding", "brutal")
	if err := configCheckKeys(object, allowed, "multiplex"); err != nil {
		return multiplex, err
	}
	if _, present := object["enabled"]; present {
		multiplex.enabled = configJSONBoolValue(object["enabled"])
		multiplex.unspecified = false
	} else {
		multiplex.unspecified = true
	}
	if _, present := object["protocol"]; present {
		multiplex.protocol = configJSONString(object, "protocol")
	}
	if _, present := object["max_connections"]; present {
		multiplex.maxConnections = configJSONInt(object["max_connections"])
	}
	if _, present := object["min_streams"]; present {
		multiplex.minStreams = configJSONInt(object["min_streams"])
	}
	if _, present := object["max_streams"]; present {
		multiplex.maxStreams = configJSONInt(object["max_streams"])
	}
	if _, present := object["padding"]; present {
		multiplex.padding = configJSONBoolValue(object["padding"])
	}
	if brutal := configJSONObjectValue(object["brutal"]); brutal != nil {
		if err := configCheckKeys(brutal, configKeysAllowed("enabled", "up_mbps", "down_mbps"), "multiplex.brutal"); err != nil {
			return multiplex, err
		}
		if _, present := brutal["enabled"]; present {
			multiplex.brutal.enabled = configJSONBoolValue(brutal["enabled"])
		}
		if _, present := brutal["up_mbps"]; present {
			multiplex.brutal.upMbps = configJSONInt(brutal["up_mbps"])
		}
		if _, present := brutal["down_mbps"]; present {
			multiplex.brutal.downMbps = configJSONInt(brutal["down_mbps"])
		}
	}
	return multiplex, nil
}

// hasOwnSettings is Multiplex.HasOwnSettings.
func (multiplex configMultiplexParams) hasOwnSettings() bool {
	return multiplex.protocol != "" || multiplex.maxConnections > 0 || multiplex.minStreams > 0 ||
		multiplex.maxStreams > 0 || multiplex.padding || multiplex.brutal.enabled
}

// isCustom is Multiplex.IsCustom.
func (multiplex configMultiplexParams) isCustom() bool {
	return !multiplex.unspecified && multiplex.enabled && multiplex.hasOwnSettings()
}

// effectivelyOn is Multiplex.EffectivelyOn.
func (multiplex configMultiplexParams) effectivelyOn(settings simpleConfigSettings) bool {
	return multiplex.enabled || (multiplex.unspecified && settings.MuxDefaultOn)
}

// configMuxSettings is MuxSettings (the values MuxSettings::Build consumes).
type configMuxSettings struct {
	protocol       string
	byConnections  bool
	maxStreams     int
	maxConnections int
	minStreams     int
	padding        bool
	brutal         bool
	brutalUpMbps   int
	brutalDownMbps int
}

// configMuxPreset is MuxSettings::Preset from BuildContext's globals.
func configMuxPreset(settings simpleConfigSettings) configMuxSettings {
	return configMuxSettings{
		protocol:       settings.MuxProtocol,
		byConnections:  settings.MuxMode == "max_connections",
		maxStreams:     settings.MuxConcurrency,
		maxConnections: settings.MuxMaxConnections,
		minStreams:     settings.MuxMinStreams,
		padding:        settings.MuxPadding,
		brutal:         settings.MuxBrutal,
		brutalUpMbps:   settings.MuxBrutalUpMbps,
		brutalDownMbps: settings.MuxBrutalDownMbps,
	}
}

// customSettings is Multiplex.CustomSettings: the pool is taken as a whole,
// padding and brutal come from the profile only.
func (multiplex configMultiplexParams) customSettings(settings simpleConfigSettings) configMuxSettings {
	preset := configMuxPreset(settings)
	if !multiplex.hasOwnSettings() {
		return preset
	}
	mux := preset
	mux.padding = multiplex.padding
	mux.brutal = multiplex.brutal.enabled
	if multiplex.protocol != "" {
		mux.protocol = multiplex.protocol
	}
	if multiplex.maxConnections > 0 {
		mux.byConnections = true
		mux.maxConnections = multiplex.maxConnections
		mux.minStreams = multiplex.minStreams
	} else if multiplex.maxStreams > 0 {
		mux.byConnections = false
		mux.maxStreams = multiplex.maxStreams
	}
	if multiplex.brutal.enabled {
		mux.brutalUpMbps = multiplex.brutal.upMbps
		mux.brutalDownMbps = multiplex.brutal.downMbps
	}
	return mux
}

// configMuxSettingsBuild is MuxSettings::Build.
func configMuxSettingsBuild(mux configMuxSettings) map[string]any {
	object := map[string]any{"enabled": true}
	if mux.protocol != "" {
		object["protocol"] = mux.protocol
	}
	if mux.byConnections {
		if mux.maxConnections > 0 {
			object["max_connections"] = mux.maxConnections
		}
		if mux.minStreams > 0 {
			object["min_streams"] = mux.minStreams
		}
	} else if mux.maxStreams > 0 {
		object["max_streams"] = mux.maxStreams
	}
	if mux.padding {
		object["padding"] = true
	}
	if mux.brutal {
		up := mux.brutalUpMbps
		if up <= 0 {
			up = 1
		}
		down := mux.brutalDownMbps
		if down <= 0 {
			down = 1
		}
		object["brutal"] = map[string]any{"enabled": true, "up_mbps": up, "down_mbps": down}
	}
	return object
}

// configMultiplexBuild is Multiplex.Build.
func configMultiplexBuild(multiplex configMultiplexParams, settings simpleConfigSettings) map[string]any {
	if !multiplex.effectivelyOn(settings) {
		return map[string]any{}
	}
	if multiplex.isCustom() {
		return configMuxSettingsBuild(multiplex.customSettings(settings))
	}
	return configMuxSettingsBuild(configMuxPreset(settings))
}
