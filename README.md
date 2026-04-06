# Copilot Local 🛫

Run the GitHub Copilot CLI with **local models** — no internet, no API keys, no auth required. True airplane mode.

## What This Does

Redirects the GitHub Copilot CLI's model calls to a local inference server ([Ollama](https://ollama.com) or [Foundry Local](https://github.com/microsoft/foundry-local)) running on your machine. You get the full Copilot CLI TUI experience powered by models running entirely on your hardware.

| Backend | Model | Size | Speed (CPU) | Script |
|---------|-------|------|-------------|--------|
| Ollama | Gemma 4 E2B | 7.2 GB | ~30-40s/turn | `launch-ollama.ps1` |
| Foundry Local | Phi-4 | 10 GB | ~5-10s/turn | `launch-foundry.ps1` |

## How It Works

The Copilot CLI binary (`gh copilot`) uses the OpenAI chat/completions API internally. We exploit three things:

1. **`OPENAI_BASE_URL`** — The binary reads this env var and sends requests there instead of OpenAI
2. **`--model gpt-4.1`** — We use a whitelisted model name to pass the CLI's validation
3. **Model aliasing** — We map `gpt-4.1` to the actual local model name

The binary thinks it's talking to GPT-4.1 at OpenAI, but the requests actually go to your local server running Gemma/Phi.

```
Copilot CLI → "gpt-4.1" → OPENAI_BASE_URL → localhost → Ollama/Foundry → Gemma/Phi responds
```

### MCP Tool Limit

The Copilot CLI sends all configured tools (MCP servers, plugins, skills, agents) to the model. Local models typically have a 128-tool limit. If you have many MCP servers configured, the scripts temporarily hide the MCP config files and restore them when you exit.

---

## Option 1: Ollama + Gemma 4

### Prerequisites

- [Ollama](https://ollama.com) installed
- GitHub Copilot CLI installed (`gh extension install github/gh-copilot`)
- Node.js (ships with Copilot CLI)

### Setup

```powershell
# Install Ollama and pull Gemma
winget install Ollama.Ollama   # or download from ollama.com
ollama pull gemma4:e2b          # 7.2 GB download

# Create a model alias so Ollama responds to "gpt-4.1"
ollama cp gemma4:e2b gpt-4.1
```

### Run

```powershell
.\launch-ollama.ps1
# Or with flags:
.\launch-ollama.ps1 --yolo
```

---

## Option 2: Foundry Local + Phi-4

### Prerequisites

- [Foundry Local](https://github.com/microsoft/foundry-local) installed
- GitHub Copilot CLI installed
- Node.js

### Setup

```powershell
# Install Foundry Local
winget install Microsoft.FoundryLocal   # or from GitHub releases

# Download Phi-4 (happens automatically on first run, ~10 GB)
foundry model run phi-4
```

### Run

```powershell
.\launch-foundry.ps1
# Or with flags:
.\launch-foundry.ps1 --yolo
```

The Foundry script starts a tiny proxy server (`foundry-proxy.cjs`) that rewrites the model name from `gpt-4.1` to Foundry's internal ID (`Phi-4-generic-cpu:1`). The proxy auto-starts and auto-stops with the script.

---

## Using Other Models

### Ollama (any model)

```powershell
# Pull any model
ollama pull llama3.3:70b

# Create the alias
ollama cp llama3.3:70b gpt-4.1

# Run
.\launch-ollama.ps1
```

### Foundry Local (other models)

Edit the `MODEL_MAP` in `foundry-proxy.cjs` to add your model's Foundry ID:

```javascript
const MODEL_MAP = {
  'gpt-4.1': 'YOUR-MODEL-ID-HERE',
};
```

Find model IDs with `foundry model list`.

---

## How to Verify It's Actually Local

1. **Disconnect from the internet** — it still works ✅
2. **Check the API key** — it's set to `'ollama'` or `'foundry-local'` (fake keys that no cloud provider would accept)
3. **Ask "what model are you?"** — Gemma/Phi may identify themselves
4. **Stop the local server** — Copilot CLI immediately fails

---

## Limitations

- **Speed**: Local CPU inference is 10-50x slower than cloud. GPU helps significantly.
- **Tool calling**: Some local models have limited tool calling support. MCP tools may not work.
- **128 tool limit**: MCP configs are temporarily hidden. Your cloud Copilot session is unaffected.
- **Model quality**: Local 7-14B models are less capable than Claude/GPT for complex coding tasks.
- **Windows only**: Scripts are PowerShell. Linux/macOS adaptation is straightforward (PRs welcome!).

---

## Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│ Copilot CLI  │────▶│  OPENAI_BASE_URL │────▶│  Local Server   │
│ (TUI)        │     │  localhost:11434  │     │  Ollama/Foundry │
│ --model      │     │  or :5272 proxy  │     │  Gemma/Phi-4    │
│  gpt-4.1     │     └──────────────────┘     └─────────────────┘
└─────────────┘            ▲
                           │ (Foundry only)
                    ┌──────┴───────┐
                    │ foundry-proxy│
                    │ Rewrites     │
                    │ model name   │
                    └──────────────┘
```

---

## Credits

Discovered during the [Squad](https://github.com/bradygaster/squad) airplane mode experiment.
Issue: [tamirdresher/tamresearch1#2173](https://github.com/tamirdresher/tamresearch1/issues/2173)

## License

MIT
