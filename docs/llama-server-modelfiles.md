# Llama.cpp Model Orchestration (Modernized Presets + Modelfiles)

This repo provides `scripts/llama_model_manager.rb`, a file-driven orchestrator designed around llama.cpp server capabilities, including existing `--models-preset` workflows.

## What this modernizes

- Keeps compatibility with **preset INI files** (`*.ini`) that mirror `llama-server --models-preset presets.ini` style.
- Adds **Modelfile-style definitions** as first-class model artifacts.
- Adds **structured YAML/JSON** model files for exact reproducibility and automation.
- Adds layered configuration:
  1. `defaults.yml`
  2. model file
  3. `overrides.yml` per model
  4. `hardware_overrides` (e.g., by detected VRAM tier)
- Adds automatic lifecycle:
  - auto-load matching models at startup
  - unload after idle timeout (default 120s)

## Config root

`~/.config/llama/models/`

```text
~/.config/llama/models/
  defaults.yml
  overrides.yml
  qwen3_6.modelfile
  coding.yml
  presets.ini
  assistants/
    support.yaml
```

## Accepted model formats

### 1) Structured YAML/JSON

```yaml
name: qwen3.6-instruct
model: /models/Qwen3.6-32B-Instruct-Q4_K_M.gguf
template: qwen3
system: You are a precise coding assistant.
tags: [default, coding]
params:
  n_ctx: 32768
  n_gpu_layers: 70
  temp: 0.2
speculative:
  model: /models/Qwen3.6-4B-Draft-Q8_0.gguf
  max_draft: 16
  min_draft: 4
hardware_overrides:
  vram_0_15:
    params:
      n_ctx: 8192
      n_gpu_layers: 20
  vram_16_23:
    params:
      n_ctx: 16384
      n_gpu_layers: 45
  vram_24_1000:
    params:
      n_ctx: 32768
      n_gpu_layers: 70
```

### 2) Modelfile-style

Supported tokens:
- `NAME`
- `FROM`
- `TEMPLATE`
- `SYSTEM`
- `PARAMETER key value`
- `TAG`
- `SPECULATIVE_MODEL`
- `SPECULATIVE_MAX`
- `SPECULATIVE_MIN`

Example (`qwen3_6.modelfile`):

```text
NAME qwen3.6-instruct
FROM /models/Qwen3.6-32B-Instruct-Q4_K_M.gguf
TEMPLATE {{- if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{- end }}<|im_start|>user
{{ .Prompt }}<|im_end|>
<|im_start|>assistant
SYSTEM You are a senior software architect. Prefer concise, actionable output.
TAG default
TAG coding
PARAMETER n_ctx 32768
PARAMETER n_gpu_layers 70
PARAMETER temp 0.2
PARAMETER top_p 0.9
SPECULATIVE_MODEL /models/Qwen3.6-4B-Draft-Q8_0.gguf
SPECULATIVE_MAX 16
SPECULATIVE_MIN 4
```

### 3) Presets INI (`*.ini`)

INI sections are parsed and passed as a `preset` payload to the server adapter endpoint (`/slots`).

```ini
[main]
model=/models/Qwen3.6-32B-Instruct-Q4_K_M.gguf
ctx-size=32768
gpu-layers=70
chat-template=qwen3

[speculative]
model=/models/Qwen3.6-4B-Draft-Q8_0.gguf
max-draft=16
min-draft=4
```

## Defaults + overrides

`defaults.yml`

```yaml
params:
  temp: 0.2
  top_p: 0.9
  n_ctx: 8192
```

`overrides.yml`

```yaml
models:
  qwen3.6-instruct:
    params:
      n_ctx: 16384
```

## Hardware-aware overrides

The manager detects (when possible):
- NVIDIA VRAM (`nvidia-smi`)
- system RAM
- GPU name (NVIDIA or ROCm hint)

Use model-level `hardware_overrides` tiers like:
- `vram_0_15`
- `vram_16_23`
- `vram_24_1000`

The highest matching tier is applied.

## Lifecycle behavior

- Polls config root every `poll_interval_seconds` (default: 5).
- Auto-loads models matching `match.autoload_tags` (or all, if empty).
- Unloads loaded models after `idle_timeout_seconds` (default: 120).

## Runtime manager config

```yaml
server_url: http://127.0.0.1:8080
models_root: ~/.config/llama/models
idle_timeout_seconds: 120
poll_interval_seconds: 5
autoload: true
match:
  autoload_tags: [default]
hardware:
  detect_gpu: true
  vram_gb: null
  ram_gb: null
```

Run:

```bash
./scripts/llama_model_manager.rb
# or
./scripts/llama_model_manager.rb ~/.config/llama/manager.yml
```
