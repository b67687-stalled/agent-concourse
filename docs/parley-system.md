# Parley --- Multi-Agent Conversation System

A web-based platform where multiple free AI agents talk to each other in real-time,
visible as a circle visualization with speech bubbles. Agents can debate, brainstorm,
or have free-form conversations that are recorded for analysis.

---

## Quick Start

```bash
python3 ./agent-concourse/web/server.py
# Open http://localhost:8080
```

Requires an OpenRouter API key (auto-detected from your OpenCode auth store).

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  Frontend (static/index.html)                              │
│  ┌──────────────────┐  ┌────────────────────────────────┐ │
│  │ Circle Canvas    │  │ Conversation Log               │ │
│  │ (orbit agents)   │  │ (left sidebar, scroll-aware)   │ │
│  │ center bubble    │  │ markdown rendered              │ │
│  │ glow effects)    │  │ expandable messages            │ │
│  └──────────────────┘  └────────────────────────────────┘ │
│              │ EventSource (SSE)                           │
└──────────────┼────────────────────────────────────────────┘
               │
┌──────────────┼────────────────────────────────────────────┐
│  Backend (server.py)                                      │
│  ┌──────────┴──────────┐  ┌────────────────────────────┐ │
│  │ HTTP Server         │  │ Conversation Runner        │ │
│  │ /api/start          │  │ parallel-first / sequential│ │
│  │ /stream/<id>  (SSE) │  │ rate limited (3s min gap)  │ │
│  │ /api/panels/       │  │ exponential backoff on 429 │ │
│  │ /api/pool          │  │ backup model fallback       │ │
│  │ /api/summarize/    │  └────────────────────────────┘ │
│  │ /api/sessions      │                                  │
│  └────────────────────┘                                   │
└───────────────────────────────────────────────────────────┘
```

### Core Loop

1. User picks topic + panel size + optional specific models -> clicks Start
2. Server creates session, queues SSE events, launches conversation in background thread
3. **Round 1 (parallel-first mode):** All agents called simultaneously (with 2s stagger for rate limits)
4. **Frontend buffers messages** and displays them one at a time (1.8s interval)
5. **Rounds 2+ (sequential):** Agents take turns, each seeing full conversation history
6. Session saved to `sessions/<timestamp>-<slug>/` with JSON + markdown transcript
7. "Generate Summary" button calls an AI to summarize agreements and disagreements

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Serve frontend |
| GET | `/api/pool` | List all available models |
| GET | `/api/panels/<name>` | Get panel definition (auto-# generates from pool) |
| POST | `/api/start` | Start a conversation |
| GET | `/stream/<id>` | SSE event stream for live conversation |
| GET | `/api/sessions` | List past sessions |
| GET | `/api/session/<id>` | Get session JSON data |
| GET | `/api/summarize/<id>` | AI-generated summary of a session |
| GET | `/api/key-check` | Check if API key is configured |

### `/api/start` request body

```json
{
  "topic": "Should we bootstrap?",
  "panel": "auto-3",          // or named panel like "3-fast"
  "rounds": 3,
  "mode": "parallel-first",   // or "sequential"
  "max_tokens": 200,
  "models": ["minimax/minimax-m2.5:free"]  // optional: pick specific models
}
```

---

## SSE Event Types

| Event | Fields | Description |
|-------|--------|-------------|
| `session_start` | `session_id`, `topic`, `agents`, `rounds` | Initial session info |
| `round_start` | `round`, `total` | New round begins |
| `thinking` | `agent_index`, `agent_name`, `model` | Agent is generating |
| `message` | `agent_index`, `agent_name`, `content`, `latency_s`, `model_short` | Agent response |
| `error` | `message` | Error occurred |
| `end` | `message_count`, `session_id` | Conversation complete |

Messages are buffered on the frontend and displayed sequentially at 1.8s intervals
to prevent visual overload when agents respond in parallel.

---

## Panel System

### Named Panels (fixed presets)

| Panel | Agents | Use Case |
|-------|--------|----------|
| `2-duel` | Analyst, Challenger | Fast 1-on-1 |
| `3-fast` | Analyst, Challenger, Closer | Fast 3-agent |
| `3-debate` | Guide, Analyst, Challenger | Structured debate |
| `5-diverse` | Guide, Optimist, Skeptic, Analyst, Bridge | Multiple perspectives |
| `7-council` | Guide, Strategist, Skeptic, Analyst, Creator, Historian, Bridge | Full council |

### Auto Panels (dynamic)

`auto-2`, `auto-3`, `auto-5` --- Generates agents by cycling through the model pool
and assigning generic archetypes (Analyst, Challenger, Closer, Guide, etc.).

The 🔧 button opens a model picker where you can select specific models. Your
selection is locked in for the session.

### Model Pool

All 24 free OpenRouter models are in the pool. The rate limiter and backup fallback
handle failures gracefully:
- 3s minimum between requests
- 8 req/min cap
- 5s -> 10s -> 20s backoff on 429 errors
- Falls through backup models on saturation

---

## Frontend Components

### Circle Canvas

- Agents arranged on a dashed orbit circle
- Speaking agent highlighted with large glow (+55px radius, two-stop radial gradient)
- Thinking agent shows elapsed seconds + animated dots
- Ghost avatar center + speech bubble with ~150-char summary
- Bubble auto-fades after 4 seconds
- All agents stay at fixed orbit positions (no center movement animation)

### Conversation Log

- Left sidebar, 420px wide
- Markdown rendered (bold, italic, code, lists, headers)
- Messages >250 chars are expandable ("Show more" shows full content)
- Scroll-aware: if you're at the bottom, auto-scrolls; if scrolled up, "v New messages" indicator
- User can inject their own messages via the input at the bottom
- "Generate Summary" button appears after session ends

### Session List

- Hidden by default --- toggled via 📋 Sessions button in header
- Shows recent 10 sessions with topic and message count
- Click to open session JSON in new tab

---

## Key Learnings

1. **Free model volatility:** OpenRouter free tier models come and go constantly.
   Of 24 listed free models, typically only 2-4 work at any given time. The rest
   return HTTP 429 (rate limited) or HTTP 400/NoneType (broken).

2. **Rate limiting is critical:** Free tier allows ~10 requests/min. Parallel
   execution needs 2s+ stagger between thread launches. Sequential needs 2s
   between agent turns. Exponential backoff (5s -> 10s -> 20s) on 429 errors.

3. **Parallel-first is best:** Launching all agents simultaneously (Round 1)
   then switching to sequential (Rounds 2+) is ~3x faster than pure sequential.
   The frontend buffers parallel responses and displays them one at a time.

4. **Markdown rendering is essential:** Every AI model outputs markdown by default
   (bold, lists, code blocks). Without rendering, the log is unreadable.

5. **Centralized animation is simpler:** Moving agents to/from center caused
   visual glitches with auto-arrangement. Keeping all agents at fixed orbit
   positions with a center ghost + glow highlight is cleaner.

6. **Auto-panels > fixed panels:** Dynamically assigning models to roles from a
   pool is more resilient than hardcoded panels. When one model dies, the pool
   still works with remaining models.

7. **Event scheduling prevents overwhelm:** When 3+ agents respond simultaneously,
   displaying all at once is confusing. A 1.8s interval between displayed messages
   gives the user time to read each one.

8. **Scroll position must be captured before DOM mutation:** `isScrolledToBottom()`
   checked after appending content will always fail (scrollHeight increased).
   Save `wasAtBottom` before adding content, use `requestAnimationFrame` for
   post-render scroll.

---

## File Structure

```
agent-concourse/
├── web/
│   ├── server.py           # Python backend (asyncio-free, stdlib only)
│   ├── benchmark.py        # Speed benchmark tool
│   └── static/
│       └── index.html      # Single-page frontend (CSS + JS inline)
├── panels/
│   ├── 2-duel.json
│   ├── 3-debate.json
│   ├── 3-fast.json
│   ├── 5-diverse.json
│   └── 7-council.json
├── sessions/               # Recorded conversations (gitignored)
└── benchmark-results.json
scripts/
└── parley-web.sh           # Convenience launcher
```

---

## Recurring Issues

- **Model saturation:** All free models may return 429 simultaneously. The rate
  limiter helps but cannot fix demand > supply. A paid OpenRouter API key is the
  real solution.
- **Panel drift:** As models appear/disappear from the free tier, the auto-pool
  handles it, but named panels with hardcoded models may silently fail.
- **Session files accumulate:** Old test sessions in `sessions/` should be cleaned
  up periodically.
