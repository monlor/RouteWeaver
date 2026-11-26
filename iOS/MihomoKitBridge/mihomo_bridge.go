package mihomokit

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"sync"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const defaultMemoryLimitMB int64 = 32

var (
	mu             sync.Mutex
	running        bool
	currentHomeDir string
	currentTunFD   int32
	memLimitSet    bool
)

// SetMemoryLimitMB configures Go's soft memory limit and aggressive GC target
// so the NetworkExtension stays well below iOS's 50 MB memory cap.
func SetMemoryLimitMB(mb int64) {
	if mb <= 0 {
		mb = defaultMemoryLimitMB
	}
	mu.Lock()
	defer mu.Unlock()
	debug.SetGCPercent(20)
	debug.SetMemoryLimit(mb * 1024 * 1024)
	memLimitSet = true
}

// Start initializes Mihomo's home directory, applies configJSON (injecting tunFD
// when > 0), and starts the Mihomo hub inside NEPacketTunnelProvider.
func Start(homeDir string, configJSON string, tunFD int32) error {
	if homeDir == "" {
		return errors.New("mihomokit: homeDir must not be empty")
	}
	if configJSON == "" {
		return errors.New("mihomokit: configJSON must not be empty")
	}

	mu.Lock()
	defer mu.Unlock()

	if !memLimitSet {
		debug.SetGCPercent(20)
		debug.SetMemoryLimit(defaultMemoryLimitMB * 1024 * 1024)
		memLimitSet = true
	}

	if running {
		stopLocked()
	}

	if err := os.MkdirAll(homeDir, 0o755); err != nil {
		return fmt.Errorf("mihomokit: failed to create homeDir: %w", err)
	}

	normalized, err := normalizeConfig(configJSON, tunFD)
	if err != nil {
		return err
	}

	configPath := filepath.Join(homeDir, "config.json")
	if err := os.WriteFile(configPath, normalized, 0o600); err != nil {
		return fmt.Errorf("mihomokit: failed to write config.json: %w", err)
	}

	constant.SetHomeDir(homeDir)
	constant.SetConfig(configPath)

	if err := hub.Parse(normalized); err != nil {
		return fmt.Errorf("mihomokit: hub.Parse failed: %w", err)
	}

	running = true
	currentHomeDir = homeDir
	currentTunFD = tunFD
	return nil
}

// Reload hot-reloads the Mihomo configuration without tearing down the VPN tunnel.
func Reload(configJSON string) error {
	if configJSON == "" {
		return errors.New("mihomokit: configJSON must not be empty")
	}

	mu.Lock()
	defer mu.Unlock()

	if !running {
		return errors.New("mihomokit: engine is not running")
	}

	normalized, err := normalizeConfig(configJSON, currentTunFD)
	if err != nil {
		return err
	}

	if currentHomeDir != "" {
		configPath := filepath.Join(currentHomeDir, "config.json")
		if err := os.WriteFile(configPath, normalized, 0o600); err != nil {
			return fmt.Errorf("mihomokit: failed to write config.json: %w", err)
		}
	}

	if err := hub.Parse(normalized); err != nil {
		return fmt.Errorf("mihomokit: reload hub.Parse failed: %w", err)
	}

	debug.FreeOSMemory()
	return nil
}

// Stop gracefully closes active connections and shuts down the Mihomo engine.
func Stop() error {
	mu.Lock()
	defer mu.Unlock()

	if !running {
		return nil
	}

	stopLocked()
	return nil
}

// IsRunning reports whether the Mihomo engine is currently active.
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return running
}

// Version returns the embedded Mihomo core version string.
func Version() string {
	if constant.Version == "" {
		return "mihomo"
	}
	return constant.Version
}

func stopLocked() {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
	executor.Shutdown()
	running = false
	currentTunFD = 0
	debug.FreeOSMemory()
}

func normalizeConfig(configJSON string, tunFD int32) ([]byte, error) {
	var cfg map[string]any
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		return nil, fmt.Errorf("mihomokit: invalid config JSON: %w", err)
	}
	if cfg == nil {
		cfg = make(map[string]any)
	}

	// Apply iOS NetworkExtension low-memory defaults when omitted.
	if _, exists := cfg["geodata-mode"]; !exists {
		cfg["geodata-mode"] = false
	}
	if profileRaw, ok := cfg["profile"].(map[string]any); ok {
		if _, exists := profileRaw["store-selected"]; !exists {
			profileRaw["store-selected"] = false
		}
		if _, exists := profileRaw["store-fake-ip"]; !exists {
			profileRaw["store-fake-ip"] = false
		}
	} else if _, exists := cfg["profile"]; !exists {
		cfg["profile"] = map[string]any{
			"store-selected": false,
			"store-fake-ip":  false,
		}
	}

	if tunFD > 0 {
		tunCfg, ok := cfg["tun"].(map[string]any)
		if !ok || tunCfg == nil {
			tunCfg = make(map[string]any)
		}
		tunCfg["enable"] = true
		tunCfg["file-descriptor"] = int(tunFD)
		if _, exists := tunCfg["stack"]; !exists {
			tunCfg["stack"] = "gvisor"
		}
		if _, exists := tunCfg["auto-route"]; !exists {
			tunCfg["auto-route"] = false
		}
		if _, exists := tunCfg["auto-detect-interface"]; !exists {
			tunCfg["auto-detect-interface"] = false
		}
		cfg["tun"] = tunCfg
	}

	out, err := json.Marshal(cfg)
	if err != nil {
		return nil, fmt.Errorf("mihomokit: failed to marshal normalized config: %w", err)
	}
	return out, nil
}
