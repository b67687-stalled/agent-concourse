#!/usr/bin/env python3
"""
Parley Speed Benchmark --- tests every free model for latency
============================================================
Usage: python3 agent-concourse/web/benchmark.py [--rounds 3]
"""

import json, os, sys, time, urllib.request, urllib.error
from pathlib import Path

# API Key
OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY", "")
if not OPENROUTER_API_KEY:
    af = Path.home() / ".local" / "share" / "opencode" / "auth.json"
    if af.exists():
        auth = json.loads(af.read_text())
        OPENROUTER_API_KEY = auth.get("openrouter", {}).get("key", "")
if not OPENROUTER_API_KEY:
    print("No API key found")
    sys.exit(1)

# Models to test (all :free candidates)
MODELS = [
    "z-ai/glm-4.5-air:free",
    "google/gemma-4-31b:free",
    "minimax/minimax-m2.5:free",
    "tencent/hy3-preview:free",
    "nvidia/nemotron-3-super:free",
    "openai/gpt-oss-120b:free",
]

TEST_PROMPT = [
    {"role": "system", "content": "You are a helpful assistant. Respond concisely in 2-3 sentences."},
    {"role": "user", "content": "What is one key factor to consider when deciding whether to bootstrap or raise VC funding? Give a brief answer."},
]

ROUNDS = int(sys.argv[sys.argv.index("--rounds")+1]) if "--rounds" in sys.argv else 2

def call_model(model, max_tokens=200):
    payload = json.dumps({
        "model": model, "messages": TEST_PROMPT,
        "temperature": 0.3, "max_tokens": max_tokens,
    }).encode()
    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=payload,
        headers={
            "Authorization": f"Bearer {OPENROUTER_API_KEY}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/B67687/agentic-workflows",
            "X-Title": "parley-benchmark",
        },
    )
    try:
        start = time.time()
        with urllib.request.urlopen(req, timeout=180) as resp:
            data = json.loads(resp.read())
            content = data["choices"][0]["message"]["content"]
            elapsed = time.time() - start
            tokens = data.get("usage", {}).get("completion_tokens", len(content)//4)
            # Calculate tokens per second
            tps = tokens / elapsed if elapsed > 0 else 0
            return {"ok": True, "latency": round(elapsed, 1), "tokens": tokens, "tps": round(tps, 1), "content_len": len(content)}
    except Exception as e:
        return {"ok": False, "error": str(e)}

print("═" * 65)
print("  Parley Speed Benchmark")
print("═" * 65)
print(f"\n  Testing {len(MODELS)} models, {ROUNDS} rounds each")
print(f"  Prompt: {TEST_PROMPT[1]['content'][:60]}...")
print(f"  Max tokens: 200\n")

results = {}
for model in MODELS:
    name = model.split("/")[-1].replace(":free", "")
    latencies = []
    errors = []
    print(f"  [{name}] ", end="", flush=True)

    for r in range(ROUNDS):
        result = call_model(model)
        if result["ok"]:
            latencies.append(result["latency"])
            print(f"{result['latency']}s ", end="", flush=True)
        else:
            errors.append(result["error"])
            print(f"ERR ", end="", flush=True)
        time.sleep(0.5)

    print()
    results[model] = {"latencies": latencies, "errors": errors}

print("\n" + "═" * 65)
print("  Results")
print("═" * 65)
print(f"\n  {'Model':<30} {'Avg':>6} {'Min':>6} {'Max':>6} {'Runs':>5} {'Errors':>6}")
print("  " + "─" * 65)
for model, data in results.items():
    name = model.split("/")[-1].replace(":free", "")
    if data["latencies"]:
        avg = sum(data["latencies"]) / len(data["latencies"])
        mn = min(data["latencies"])
        mx = max(data["latencies"])
        runs = len(data["latencies"])
        errs = len(data["errors"])
        print(f"  {name:<30} {avg:>5.1f}s {mn:>5.1f}s {mx:>5.1f}s {runs:>5} {errs:>5}")
    else:
        print(f"  {name:<30} {'FAIL':>6} {'':>6} {'':>6} {0:>5} {len(data['errors']):>5}")

# Rank by speed
ranked = [(model, data) for model, data in results.items() if data["latencies"]]
ranked.sort(key=lambda x: sum(x[1]["latencies"])/len(x[1]["latencies"]))

print("\n" + "─" * 65)
print("  Speed Ranking (fastest first):")
for i, (model, data) in enumerate(ranked):
    avg = sum(data["latencies"]) / len(data["latencies"])
    name = model.split("/")[-1].replace(":free", "")
    print(f"  {i+1}. {name:<30} {avg:.1f}s avg")

print("\n" + "═" * 65)

# Output JSON for downstream use
out = {
    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "rounds": ROUNDS,
    "models": results,
    "ranking": [m for m, _ in ranked],
}
(Path(__file__).resolve().parent.parent / "benchmark-results.json").write_text(json.dumps(out, indent=2))
print(f"\n  Full results saved to agent-concourse/benchmark-results.json")
print("═" * 65)
