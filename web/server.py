#!/usr/bin/env python3
"""
Parley Web Server --- Circle UI backend
=======================================
Starts conversations, streams agent responses via SSE, serves the frontend.

Usage:
    python3 agent-concourse/web/server.py [--port 8080]

Requires: Python 3.8+, OPENROUTER_API_KEY (env var or OpenCode auth)
"""

import os, sys, json, time, threading, queue, urllib.request, urllib.error
import http.server
import socketserver
import re
from pathlib import Path

# === Paths ===
ROOT = Path(__file__).resolve().parent.parent.parent
PANELS_DIR = ROOT / "agent-concourse" / "panels"
SESSIONS_DIR = ROOT / "agent-concourse" / "sessions"
STATIC_DIR = ROOT / "agent-concourse" / "web" / "static"

# === API Key ===
OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY", "")
if not OPENROUTER_API_KEY:
    auth_file = Path.home() / ".local" / "share" / "opencode" / "auth.json"
    if auth_file.exists():
        try:
            auth = json.loads(auth_file.read_text())
            OPENROUTER_API_KEY = auth.get("openrouter", {}).get("key", "")
        except (json.JSONDecodeError, KeyError):
            pass

if not OPENROUTER_API_KEY:
    print("WARNING: No OpenRouter API key found. Set OPENROUTER_API_KEY or configure OpenCode auth.", file=sys.stderr)

# === Active Queues (SSE) ===
active_queues: dict[str, queue.Queue] = {}

# === Model Pool (all free OpenRouter models) ===
MODEL_POOL = [
    {"id": "baidu/cobuddy:free", "name": "Baidu CoBuddy"},
    {"id": "baidu/qianfan-ocr-fast:free", "name": "Baidu Qianfan OCR"},
    {"id": "cognitivecomputations/dolphin-mistral-24b-venice-edition:free", "name": "Dolphin Mistral 24B"},
    {"id": "google/gemma-4-26b-a4b-it:free", "name": "Gemma 4 26B"},
    {"id": "google/gemma-4-31b-it:free", "name": "Gemma 4 31B"},
    {"id": "liquid/lfm-2.5-1.2b-instruct:free", "name": "LFM 1.2B"},
    {"id": "liquid/lfm-2.5-1.2b-thinking:free", "name": "LFM 1.2B Thinking"},
    {"id": "meta-llama/llama-3.2-3b-instruct:free", "name": "Llama 3.2 3B"},
    {"id": "meta-llama/llama-3.3-70b-instruct:free", "name": "Llama 3.3 70B"},
    {"id": "minimax/minimax-m2.5:free", "name": "MiniMax M2.5"},
    {"id": "nousresearch/hermes-3-llama-3.1-405b:free", "name": "Hermes 3 405B"},
    {"id": "nvidia/nemotron-3-nano-30b-a3b:free", "name": "Nemotron Nano 30B"},
    {"id": "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free", "name": "Nemotron Nano Omni"},
    {"id": "nvidia/nemotron-3-super-120b-a12b:free", "name": "Nemotron Super 120B"},
    {"id": "nvidia/nemotron-nano-12b-v2-vl:free", "name": "Nemotron Nano 12B VL"},
    {"id": "nvidia/nemotron-nano-9b-v2:free", "name": "Nemotron Nano 9B"},
    {"id": "openai/gpt-oss-120b:free", "name": "GPT-OSS-120B"},
    {"id": "openai/gpt-oss-20b:free", "name": "GPT-OSS-20B"},
    {"id": "poolside/laguna-m.1:free", "name": "Laguna M.1"},
    {"id": "poolside/laguna-xs.2:free", "name": "Laguna XS.2"},
    {"id": "qwen/qwen3-coder:free", "name": "Qwen 3 Coder"},
    {"id": "qwen/qwen3-next-80b-a3b-instruct:free", "name": "Qwen 3 Next 80B"},
    {"id": "tencent/hy3-preview:free", "name": "Tencent Hy3"},
    {"id": "z-ai/glm-4.5-air:free", "name": "GLM 4.5 Air"},
]

# Generic agent personas for auto-panels
AGENT_ARCHETYPES = [
    {"name": "Analyst", "persona": "You are in a debate. Speak naturally.\n- 2-3 sentences\n- No formatting\n- Make one clear point with a reason"},
    {"name": "Challenger", "persona": "You are in a debate. Speak naturally.\n- 2-3 sentences\n- No formatting\n- Find one flaw or blind spot\n- Ask a question at the end"},
    {"name": "Closer", "persona": "You are in a debate. Speak naturally.\n- 2-3 sentences\n- No formatting\n- Find common ground between views\n- Suggest a concrete next step"},
    {"name": "Guide", "persona": "You keep the conversation moving. Do not give opinions.\n- 2-3 sentences\n- No formatting\n- Summarize briefly, ask one question"},
    {"name": "Optimist", "persona": "You see the opportunity.\n- 2-3 sentences\n- No formatting\n- Point out upside potential\n- Be positive but grounded"},
    {"name": "Skeptic", "persona": "You look for what could go wrong.\n- 2-3 sentences\n- No formatting\n- Name one risk or hidden assumption"},
    {"name": "Bridge", "persona": "You find common ground.\n- 2-3 sentences\n- No formatting\n- Point out where people agree\n- Suggest a middle path"},
]

def generate_auto_panel(count: int, preferred_models: list = None) -> list:
    """Generate an agent panel from the model pool."""
    # Pick models from pool
    if preferred_models:
        available = [m for m in MODEL_POOL if m["id"] in preferred_models]
        # Fill remaining slots from pool
        remaining = count - len(available)
        if remaining > 0:
            for m in MODEL_POOL:
                if m not in available and len(available) < count:
                    available.append(m)
        models = available[:count]
    else:
        # Cycle through pool
        models = (MODEL_POOL * (count // len(MODEL_POOL) + 1))[:count]

    # Assign archetypes
    agents = []
    for i, model in enumerate(models):
        archetype = AGENT_ARCHETYPES[i % len(AGENT_ARCHETYPES)]
        agents.append({
            "name": archetype["name"],
            "model": model["id"],
            "model_short": model["id"].split("/")[-1].replace(":free", ""),
            "temperature": 0.6,
            "max_tokens": 250,
            "persona": archetype["persona"],
        })
    return agents

# === Backup models for saturation fallback ===
BACKUP_MODELS = [m["id"] for m in MODEL_POOL]

# === Rate limiter (OpenRouter free tier: ~10 req/min) ===
import collections
_request_timestamps = collections.deque(maxlen=20)

def _wait_for_rate_limit():
    """Enforce minimum interval between API requests."""
    now = time.time()
    # Clean old timestamps (>60s)
    while _request_timestamps and now - _request_timestamps[0] > 60:
        _request_timestamps.popleft()
    # If we've made 8+ requests in the last 60s, wait
    if len(_request_timestamps) >= 8:
        oldest = _request_timestamps[0]
        wait = max(0, 8 - (now - oldest) * len(_request_timestamps) / 8)
        if wait > 0:
            time.sleep(wait)
    # Minimum 3s between requests
    if _request_timestamps:
        last = _request_timestamps[-1]
        since_last = now - last
        if since_last < 3:
            time.sleep(3 - since_last)

def call_openrouter(model: str, messages: list, temperature: float = 0.7, max_tokens: int = 800, retry: int = 2) -> dict:
    """Call OpenRouter API with rate limiting, exponential backoff and backup model fallback."""
    _wait_for_rate_limit()

    models_to_try = [model]
    # Add backup models (different from primary)
    for bm in BACKUP_MODELS:
        if bm != model and bm not in models_to_try:
            models_to_try.append(bm)

    for attempt in range(retry + 1):
        current_model = models_to_try[min(attempt, len(models_to_try) - 1)]
        result = _do_call_openrouter(current_model, messages, temperature, max_tokens)
        _request_timestamps.append(time.time())
        
        if result["ok"]:
            return result
        error_msg = result.get("error", "")
        # On 429, longer wait
        if "429" in error_msg or "Too Many Requests" in error_msg:
            wait_time = 5 * (2 ** attempt)  # 5, 10, 20 seconds
            if attempt < retry:
                time.sleep(wait_time)
        elif attempt < retry:
            delay = 2 ** (attempt + 1)  # 2, 4, 8 seconds
            time.sleep(delay)
    # Last attempt with reduced tokens
    if max_tokens > 100:
        return call_openrouter(models_to_try[0], messages, temperature, min(100, max_tokens), retry=1)
    return result


def _do_call_openrouter(model: str, messages: list, temperature: float = 0.7, max_tokens: int = 800) -> dict:
    """Single attempt at calling OpenRouter API."""
    payload = json.dumps({
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
    }).encode()

    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=payload,
        headers={
            "Authorization": f"Bearer {OPENROUTER_API_KEY}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/B67687/agentic-workflows",
            "X-Title": "agentic-workflows parley-web",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            data = json.loads(resp.read())
            content = data["choices"][0]["message"]["content"]
            return {"ok": True, "content": content}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def run_conversation(session_id: str, topic: str, panel_name: str, rounds: int,
                     mode: str = "parallel-first", max_tokens_override: int = 0,
                     custom_agents: list = None):
    """Run the conversation loop and push events to the SSE queue.
    
    mode: "sequential" = round-robin always
          "parallel-first" = Round 1 all agents speak simultaneously, then sequential
    """
    q = active_queues.get(session_id)
    if q is None:
        return

    # Use provided agents or load from panel file
    panel_file = PANELS_DIR / f"{panel_name}.json"
    if custom_agents:
        agents = custom_agents
        agent_count = len(agents)
    else:
        if not panel_file.exists():
            q.put({"type": "error", "message": f"Panel not found: {panel_name}"})
            q.put({"type": "end"})
            return
        panel = json.loads(panel_file.read_text())
        agents = panel["agents"]
        agent_count = len(agents)

    # Create session directory
    slug = re.sub(r'[^a-z0-9]', '-', topic.lower()).strip('-')[:50]
    session_id_full = f"{time.strftime('%Y-%m-%d-%H%M%S', time.gmtime())}-{slug}"
    session_dir = SESSIONS_DIR / session_id_full
    session_dir.mkdir(parents=True, exist_ok=True)
    session_file = session_dir / "session.json"

    # Initialize session data
    session_data = {
        "session_id": session_id_full,
        "topic": topic,
        "panel": panel_name,
        "panel_file": str(panel_file),
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "rounds_total": rounds,
        "rounds_completed": 0,
        "agent_count": agent_count,
        "agents": agents,
        "messages": [],
        "summary": None,
    }
    session_file.write_text(json.dumps(session_data, indent=2))

    # Add model_short to each agent
    for a in agents:
        if "model_short" not in a:
            a["model_short"] = a["model"].split("/")[-1].replace(":free", "")

    q.put({"type": "session_start", "session_id": session_id_full, "topic": topic, "agents": agents, "rounds": rounds})

    try:
        for round_num in range(1, rounds + 1):
            q.put({"type": "round_start", "round": round_num, "total": rounds})

            # ── Parallel mode for Round 1: all agents speak simultaneously ──
            if round_num == 1 and mode == "parallel-first":
                parallel_results = [None] * agent_count

                def call_agent_parallel(agent_idx):
                    agent = agents[agent_idx]
                    name = agent["name"]
                    model = agent["model"]
                    persona = agent.get("persona", "")
                    temperature = agent.get("temperature", 0.7)
                    max_tokens = int(max_tokens_override) if max_tokens_override > 0 else agent.get("max_tokens", 300)

                    msgs = [{"role": "system", "content": persona}]
                    round_msg = f"Topic: {topic}\n\nRound 1. You are {name}. State your position on this topic clearly and concisely."
                    msgs.append({"role": "user", "content": round_msg})

                    q.put({"type": "thinking", "agent_index": agent_idx, "agent_name": name, "model": model})

                    start = time.time()
                    result = call_openrouter(model, msgs, temperature, max_tokens, retry=1)
                    elapsed = round(time.time() - start, 1)

                    content = result["content"] if result["ok"] else f"[ERROR: {result.get('error', 'unknown')}]"
                    parallel_results[agent_idx] = (elapsed, content)

                # Launch all agent calls in parallel with stagger (rate-limit friendly)
                threads = []
                for i in range(agent_count):
                    t = threading.Thread(target=call_agent_parallel, args=(i,), daemon=True)
                    threads.append(t)
                    t.start()
                    time.sleep(2.0)  # Stagger to avoid rate limit bursts

                # Wait for all to complete
                for t in threads:
                    t.join()

                # Process results in order
                for agent_idx, agent in enumerate(agents):
                    name = agent["name"]
                    model = agent["model"]
                    elapsed, content = parallel_results[agent_idx]

                    msg_record = {
                        "round": round_num, "agent_index": agent_idx,
                        "agent_name": name, "model": model,
                        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                        "content": content, "latency_s": elapsed,
                    }
                    session_data["messages"].append(msg_record)
                    session_file.write_text(json.dumps(session_data, indent=2))

                    q.put({
                        "type": "message", "agent_index": agent_idx,
                        "agent_name": name, "content": content,
                        "latency_s": elapsed,
                        "model_short": model.split("/")[-1].replace(":free", ""),
                    })

                session_data["rounds_completed"] = round_num
                session_file.write_text(json.dumps(session_data, indent=2))
                continue  # Skip the sequential loop below

            # ── Sequential mode (default) ──
            for agent_idx, agent in enumerate(agents):
                name = agent["name"]
                model = agent["model"]
                persona = agent.get("persona", "")
                temperature = agent.get("temperature", 0.7)
                max_tokens = int(max_tokens_override) if max_tokens_override > 0 else agent.get("max_tokens", 300)

                # Notify thinking
                q.put({"type": "thinking", "agent_index": agent_idx, "agent_name": name, "model": model})

                # Build messages
                msgs = [{"role": "system", "content": persona}]

                if round_num == 1:
                    round_msg = f"Topic: {topic}\n\nRound 1. You are {name}. Respond to what the others have said. State your position clearly."
                else:
                    round_msg = f"Topic: {topic}\n\nRound {round_num}. You have seen all previous messages. Continue the discussion. Advance the debate."

                msgs.append({"role": "user", "content": round_msg})

                # Add history
                history = session_data["messages"]
                if len(history) > 50:
                    history = history[-50:]
                for hmsg in history:
                    msgs.append({
                        "role": "assistant",
                        "name": hmsg["agent_name"],
                        "content": hmsg["content"]
                    })

                # Call API with timing and retry
                start = time.time()
                result = call_openrouter(model, msgs, temperature, max_tokens, retry=1)
                elapsed = round(time.time() - start, 1)

                if result["ok"]:
                    content = result["content"]
                else:
                    content = f"[ERROR: {result.get('error', 'unknown')}]"

                # Build message record
                msg_record = {
                    "round": round_num,
                    "agent_index": agent_idx,
                    "agent_name": name,
                    "model": model,
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "content": content,
                    "latency_s": elapsed,
                }

                # Save to session
                session_data["messages"].append(msg_record)
                session_file.write_text(json.dumps(session_data, indent=2))

                # Notify message
                q.put({
                    "type": "message",
                    "agent_index": agent_idx,
                    "agent_name": name,
                    "content": content,
                    "latency_s": elapsed,
                    "model_short": model.split("/")[-1].replace(":free", ""),
                })

                # Rate limit delay (respect free tier)
                time.sleep(2.0)

            # Update rounds completed
            session_data["rounds_completed"] = round_num
            session_file.write_text(json.dumps(session_data, indent=2))

        # Generate transcript
        _generate_transcript(session_dir, session_data, topic, panel_name)

        q.put({"type": "end", "message_count": len(session_data["messages"]),
               "session_id": session_id_full})

    except Exception as e:
        err_msg = str(e)[:200]
        print(f"  [ERROR] Conversation failed: {err_msg}", file=sys.stderr)
        q.put({"type": "error", "message": err_msg})
        q.put({"type": "end"})
        # Don't raise - thread exits cleanly


def _generate_transcript(session_dir, session_data, topic, panel_name):
    """Generate a markdown transcript."""
    lines = [
        f"# Parley Transcript: {topic}",
        "",
        f"**Panel:** {panel_name} | **Agents:** {', '.join(a['name'] for a in session_data['agents'])}",
        f"**Rounds:** {session_data['rounds_total']} | **Messages:** {len(session_data['messages'])}",
        f"**Date:** {session_data['created']}",
        "",
        "---",
        "",
    ]
    current_round = 0
    for msg in session_data["messages"]:
        r = msg["round"]
        if r != current_round:
            current_round = r
            lines.append(f"## Round {current_round}")
            lines.append("")
        model_short = msg["model"].split("/")[-1].replace(":free", "")
        lines.append(f"### {msg['agent_name']}")
        lines.append(f"*{msg['latency_s']}s via {model_short}*")
        lines.append("")
        lines.append(msg["content"])
        lines.append("")
        lines.append("---")
        lines.append("")

    transcript_file = session_dir / "transcript.md"
    transcript_file.write_text("\n".join(lines))


# === SSE Handler ===
class ParleyHandler(http.server.BaseHTTPRequestHandler):
    """HTTP request handler for Parley web UI."""

    def log_message(self, format, *args):
        """Suppress default logging, use custom format."""
        if args[1] != 200:  # Only log non-200 responses
            msg = f"[{self.log_date_time_string()}] {args[0]} - {format % args}"
            print(msg, file=sys.stderr)

    def _send_json(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _send_file(self, path: Path, content_type: str):
        if not path.exists():
            self._send_json({"error": "Not found"}, 404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(path.read_bytes())

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]

        # API: list sessions
        if path == "/api/sessions":
            sessions = []
            if SESSIONS_DIR.exists():
                for d in sorted(SESSIONS_DIR.iterdir(), reverse=True):
                    sf = d / "session.json"
                    if sf.exists():
                        data = json.loads(sf.read_text())
                        sessions.append({
                            "session_id": data.get("session_id", d.name),
                            "topic": data.get("topic", "?"),
                            "messages": len(data.get("messages", [])),
                            "created": data.get("created", ""),
                            "panel": data.get("panel", ""),
                        })
            self._send_json(sessions)

        # API: get session data
        elif path.startswith("/api/session/"):
            sid = path.split("/api/session/")[1]
            sf = SESSIONS_DIR / sid / "session.json"
            if sf.exists():
                self._send_file(sf, "application/json")
            else:
                self._send_json({"error": "Session not found"}, 404)

        # SSE stream
        elif path.startswith("/stream/"):
            sid = path.split("/stream/")[1]
            if sid not in active_queues:
                self._send_json({"error": "No active session"}, 404)
                return

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

            q = active_queues[sid]
            try:
                while True:
                    try:
                        event = q.get(timeout=30)
                        self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
                        self.wfile.flush()
                        if event.get("type") == "end":
                            break
                    except queue.Empty:
                        self.wfile.write(b": heartbeat\n\n")
                        self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                if sid in active_queues and q.empty():
                    del active_queues[sid]

        # API: get panel data
        elif path.startswith("/api/panels/"):
            panel_name = path.split("/api/panels/")[1]
            # Auto panels
            if panel_name.startswith("auto-"):
                try:
                    count = int(panel_name.split("auto-")[1])
                    agents = generate_auto_panel(count)
                    self._send_json({"panel": panel_name, "description": f"Auto {count}-agent panel", "agents": agents})
                except ValueError:
                    self._send_json({"error": "Invalid auto panel size"}, 400)
                return
            # Named panels
            pf = PANELS_DIR / f"{panel_name}.json"
            if pf.exists():
                data = json.loads(pf.read_text())
                for a in data.get("agents", []):
                    if "model_short" not in a:
                        a["model_short"] = a["model"].split("/")[-1].replace(":free", "")
                self._send_json(data)
            else:
                self._send_json({"error": "Panel not found"}, 404)

        # API: model pool
        elif path == "/api/pool":
            self._send_json({"models": MODEL_POOL, "count": len(MODEL_POOL)})

        # API: auto-generate panel
        elif path.startswith("/api/summarize/"):
            session_id = path.split("/api/summarize/")[1]
            sf = SESSIONS_DIR / session_id / "session.json"
            if not sf.exists():
                self._send_json({"error": "Session not found"}, 404)
                return
            data = json.loads(sf.read_text())
            topic = data.get("topic", "Unknown topic")
            messages = data.get("messages", [])

            if not messages:
                self._send_json({"error": "No messages to summarize"}, 400)
                return

            # Build summary prompt
            transcript_lines = []
            for msg in messages:
                transcript_lines.append(f"{msg['agent_name']}: {msg['content']}")

            prompt = (
                f"Summarize this multi-agent debate on the topic: \"{topic}\"\n\n"
                f"Here is the conversation:\n{chr(10).join(transcript_lines)}\n\n"
                "Give a structured summary with:\n"
                "1. What everyone AGREED on (consensus points)\n"
                "2. What they DISAGREED on (unresolved differences)\n"
                "3. Key arguments made by each participant\n"
                "Keep it concise, 3-5 paragraphs. No markdown formatting."
            )

            result = call_openrouter(
                "openai/gpt-oss-120b:free",
                [
                    {"role": "system", "content": "You are a debate summarizer. Be concise and neutral."},
                    {"role": "user", "content": prompt}
                ],
                temperature=0.3,
                max_tokens=500
            )

            summary = result.get("content", "Summary generation failed.")
            if not result["ok"]:
                summary = f"[Summary unavailable: {result.get('error', 'unknown error')}]"

            # Save summary to session
            data["summary"] = summary
            sf.write_text(json.dumps(data, indent=2))

            self._send_json({"summary": summary, "session_id": session_id})

        # Serve static files
        elif path == "/" or path == "":
            self._send_file(STATIC_DIR / "index.html", "text/html; charset=utf-8")
        else:
            # Try static file
            fpath = STATIC_DIR / path.lstrip("/")
            if fpath.exists() and fpath.is_file():
                ext = fpath.suffix.lower()
                ctype = {
                    ".html": "text/html; charset=utf-8",
                    ".css": "text/css; charset=utf-8",
                    ".js": "application/javascript; charset=utf-8",
                    ".json": "application/json",
                    ".png": "image/png",
                    ".svg": "image/svg+xml",
                    ".ico": "image/x-icon",
                }.get(ext, "application/octet-stream")
                self._send_file(fpath, ctype)
            else:
                # SPA fallback: serve index.html
                self._send_file(STATIC_DIR / "index.html", "text/html; charset=utf-8")

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b"{}"
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self._send_json({"error": "Invalid JSON"}, 400)
            return

        if self.path == "/api/start":
            # Validate
            topic = data.get("topic", "").strip()
            panel_name = data.get("panel", "auto-3")
            rounds = int(data.get("rounds", 3))
            mode = data.get("mode", "parallel-first")
            max_tokens = int(data.get("max_tokens", 300))
            custom_agents = data.get("agents", None)  # Optional full agent override
            preferred_models = data.get("models", None)  # Optional model selection

            if not topic:
                self._send_json({"error": "Topic is required"}, 400)
                return

            if not OPENROUTER_API_KEY:
                self._send_json({"error": "No OpenRouter API key configured"}, 400)
                return

            # Determine agents to use
            if custom_agents:
                # Custom agent list provided directly
                pass  # Use as-is
            elif panel_name.startswith("auto-"):
                # Auto-generate from pool
                try:
                    count = int(panel_name.split("auto-")[1])
                    custom_agents = generate_auto_panel(count, preferred_models)
                except ValueError:
                    self._send_json({"error": "Invalid auto panel size"}, 400)
                    return
            else:
                # Named panel --- validate and load
                panel_file = PANELS_DIR / f"{panel_name}.json"
                if not panel_file.exists():
                    self._send_json({"error": f"Panel not found: {panel_name}"}, 400)
                    return
                panel_data = json.loads(panel_file.read_text())
                custom_agents = panel_data.get("agents", [])

            # Create session ID and queue
            session_id = f"live-{int(time.time())}"
            active_queues[session_id] = queue.Queue()

            # Start conversation in background thread
            t = threading.Thread(
                target=run_conversation,
                args=(session_id, topic, panel_name, rounds),
                kwargs={"mode": mode, "max_tokens_override": max_tokens, "custom_agents": custom_agents},
                daemon=True,
            )
            t.start()

            self._send_json({
                "session_id": session_id,
                "stream_url": f"/stream/{session_id}",
            })

        elif self.path == "/api/key-check":
            self._send_json({"has_key": bool(OPENROUTER_API_KEY)})

        else:
            self._send_json({"error": "Not found"}, 404)


def main():
    port = 8080
    if len(sys.argv) > 1 and sys.argv[1] == "--port":
        port = int(sys.argv[2])

    # Ensure static dir has index.html
    index_html = STATIC_DIR / "index.html"
    if not index_html.exists():
        print(f"ERROR: Frontend file not found at {index_html}", file=sys.stderr)
        print("Run this from the repo root or check the path.", file=sys.stderr)
        sys.exit(1)

    print(f"  Parley Web UI starting on http://localhost:{port}")
    print(f"  Press Ctrl+C to stop")
    print()

    # Use ThreadingHTTPServer for concurrent connections
    class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        allow_reuse_address = True
        daemon_threads = True

    server = ThreadedServer(("0.0.0.0", port), ParleyHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  Shutting down...")
        server.shutdown()


if __name__ == "__main__":
    main()
