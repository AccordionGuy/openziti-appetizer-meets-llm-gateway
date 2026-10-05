# A Second Opinion for the OpenZiti Appetizer Classifier

![llm-gateway meets the openziti appetizer](./docs/images/title%20card.jpg)

In [the first exercise in this series](https://github.com/AccordionGuy/openziti-appetizer-classifier), you gave the [OpenZiti Appetizer](https://openziti.io/docs/learn/appetizer/) a classifier that decides whether a message is offensive before the Appetizer relays it. That classifier is fast, free, and gives the same answer every time. It’s also confidently wrong about messages like this one:

> nobody here wants you around and everyone knows it

The classifier calls that **non-offensive, with 84% confidence**. That’s because it was trained to spot insult vocabulary, and that sentence doesn’t contain any. This sentence is cruel without using any profanity or words that by themselves are insulting. This is the sort of linguistic subtlety that the classifier misses completely.

We’re going to fix that problem in this exercise. The classifier will keep its job spotting insulting vocabulary and swear words, but when it isn’t sure, it asks for a second opinion. That second opinion will come from LLMs connected to [LLM Gateway](https://github.com/openziti/llm-gateway), NetFoundry’s open source OpenAI-compatible gateway. LLM Gateway’s job will be to decide which LLM gives that opinion: a small model on your own machine for everyday messages, and Claude for the subtle ones. You won’t change a line of the Appetizer’s code.

The whole exercise boils down to one sentence:

**The app decides whether to ask an LLM. The gateway decides which LLM answers.**

The exercise takes about an hour, and much of that is downloading models.

---

## Contents

- [What you’ll build](#what-youll-build)
- [Concepts you need](#concepts-you-need)
- [Prerequisites](#prerequisites)
- [You’ll need seven terminals](#youll-need-seven-terminals)
- [Step 1: Start from where episode 1 ended](#step-1-start-from-where-episode-1-ended)
- [Step 2: Add this episode’s files](#step-2-add-this-episodes-files)
- [Step 3: Install LLM Gateway and its test backend](#step-3-install-llm-gateway-and-its-test-backend)
- [Step 4: Start Ollama and pull the models](#step-4-start-ollama-and-pull-the-models)
- [Step 5: Get a Claude API key with a spending cap](#step-5-get-a-claude-api-key-with-a-spending-cap)
- [Step 6: Create gateway keys and load your shell](#step-6-create-gateway-keys-and-load-your-shell)
- [Step 7: Prove step one with two fake backends](#step-7-prove-step-one-with-two-fake-backends)
- [Step 8: A pool is copies, not choices](#step-8-a-pool-is-copies-not-choices)
- [Step 9: Virtual API keys](#step-9-virtual-api-keys)
- [Step 10: Semantic routing](#step-10-semantic-routing)
- [Step 11: Give the classifier a second opinion](#step-11-give-the-classifier-a-second-opinion)
- [Step 12: Swap the model behind the route](#step-12-swap-the-model-behind-the-route)
- [Step 13: Take the backend away](#step-13-take-the-backend-away)
- [Applying this to your own application](#applying-this-to-your-own-application)
- [Troubleshooting](#troubleshooting)
- [Running on Linux](#running-on-linux)
- [Reset](#reset)

---

## What you’ll build

```
  reflect client (you)
        │   OpenZiti overlay: authenticated, encrypted, no public address
        ▼
  ┌──────────────┐            ┌────────────────────┐
  │  appetizer   │ ─────────▶ │  classifier        │   confident? decides alone
  │  reflect svc │  dials by  │  from episode 1    │
  └──────────────┘    name    └─────────┬──────────┘
                                        │  says "clean" but under 90% sure?
                                        │  asks with model: "auto"
                                        ▼
                              ┌────────────────────┐
                              │  llm-gateway       │   127.0.0.1:8080
                              │  virtual keys      │
                              │  semantic routing  │
                              └─────┬────────┬─────┘
                       route:       │        │       route:
                       general      ▼        ▼       subtle
                         gemma3:4b (Ollama)   Claude Haiku 4.5
                         on your machine      Anthropic API, $5 cap
```

The classifier is still a dark service on the overlay, exactly as in the first exercise in this series. The gateway listens on `127.0.0.1` only. That’s deliberate: this exercise is about what the gateway does, and putting the gateway itself on the overlay is a story for the next one.

---

## Concepts you need

You’ll need six concepts, each one tied to something you’ll type.

| | |
|---|---|
| **LLM gateway** | A proxy that speaks the OpenAI chat-completions API to its callers and forwards each request to a model provider. Callers can ask for a specific model, or for `auto`; the gateway decides where the request goes. |
| **Provider** | Where requests end up. In this exercise, there are two: `local` (Ollama on your machine) and `anthropic` (Claude). LLM Gateway picks the provider from the model name’s prefix: `claude-*` goes to Anthropic, `gpt-*`, `o1-*` and `o3-*` go to OpenAI, and everything else goes to `local`. |
| **Endpoint pool** | Several addresses for one provider, used in turn, with health checks. Endpoints in a pool are *copies* of each other. The gateway doesn’t check which models each one has. |
| **Virtual API key** | An `sk-gw-` key the gateway issues. Callers never see the real provider key, and each virtual key can be limited to particular models and routes. |
| **Semantic routing** | When a caller asks for `auto`, the gateway turns the message into an embedding, compares it to example phrases for each route, and picks the closest. An ambiguous score goes to a small model that breaks the tie. No match at all goes to the default route. |
| **Escalation** | The classifier’s rule for when to ask: Its verdict is “clean” and its confidence is below 0.9. Confident verdicts never leave the classifier, and never cost anything. |

---

## Prerequisites

- **Exercise 1, working.** Either you’ve finished [exercise 1](https://github.com/AccordionGuy/openziti-appetizer-classifier) and haven’t reset it, or you’re willing to do its steps 1 to 7 first.
- **A Mac with Docker Desktop.** This was tested on an M5 Pro MacBook Pro with 64 GB of RAM, running macOS Tahoe. Linux should work with the changes in [Running on Linux](#running-on-linux), but it hasn’t been tested.
- **Memory for the models.** The three models in this exercise take about 23 GB of memory when they’re all loaded, most of it for `gemma3:27b`. On a machine with less, use `gemma3:12b` as the swap target in step 12. That should work, but it hasn’t been tested.
- **About 21 GB of disk** for the models, on top of episode 1’s 6 GB.
- **[Ollama](https://ollama.com/)**, tested with version 0.35.0.
- **Go 1.21 or later**, only to install one test tool. Go downloads whatever newer toolchain it needs by itself.
- **jq** (`brew install jq`) and **curl**.
- **A Claude API account** at [platform.claude.com](https://platform.claude.com). The whole exercise costs a few cents, and step 5 caps it at $5.

---

## You’ll need seven terminals

It may seem like a lot, but hey, terminal windows (or better yet, terminal tabs) are free!

Three terminals are from episode 1, and three only run background processes. This walkthrough says which terminal each command goes in.

| | Terminal | Purpose | Working directory |
|---|---|---|---|
| **1** | **commands** | `docker compose`, `ask`, `judge` | your appetizer clone |
| **2** | **client** | the reflect client, sitting at a prompt | your appetizer clone |
| **3** | **logs** | `docker compose logs -f classifier` | your appetizer clone |
| **4** | **gateway** | `llm-gateway run …`, with its log scrolling | your appetizer clone |
| **5** | **ollama** | `ollama serve` | anywhere |
| **6** | **dummy-a** | a fake backend, steps 7 and 8 only | anywhere |
| **7** | **dummy-b** | a fake backend, step 7 only | anywhere |

Arrange **Terminals 2, 3 and 4 so you can see them at the same time.** Most of what this exercise shows happens as a message in Terminal 2 produces a line in Terminal 3 and another in Terminal 4.

---

To quickly jump to the next step in this exercise, search for the next 💻 emoji.

---

## Step 1: Start from where episode 1 ended

If you’re starting fresh, do steps 1 to 7 of the [exercise 1 README](https://github.com/AccordionGuy/openziti-appetizer-classifier), then come back here. This repo’s `classifier/` folder replaces episode 1’s in step 2 below, and behaves exactly the same until you switch it on in step 11.

If you finished exercise 1 earlier, check that its stack is still running.

💻 In Terminal 1, change to the directory where you cloned the Appetizer, and get a list of 

```bash
# Terminal 1 (Appetizer clone directory)
docker compose ps -a
```

This command will output a table. The columns you should be most concerned about are `SERVICE` and `STATUS`, and you should see these values for them:

| `STATUS`        | `SERVICE`    |
|-----------------|--------------|
| `appetizer`     | `Up`         |
| `classifier`    | `Up`         |
| `init-ziti-dir` | `Exited (0)` |
| `quickstart`    | `Up`         |
| `router`        | `Up`         |

`init-ziti-dir` should show `Exited (0)`, which is normal for a one-shot setup container.

> ### If `router` or `appetizer` shows `Exited (255)`
>
> Docker Desktop probably restarted underneath them. Start them again in order, then restart the classifier so its service registers cleanly:
>
> ```bash
> # Terminal 1 (Appetizer clone directory)
> docker compose up -d router && sleep 10
> docker compose up -d appetizer && sleep 10
> docker compose restart classifier
> ```
>
> If the reflect client later fails with `no edge routers connected in time`, this is almost always why.

💻 Confirm the classifier is still hosting its service:

```bash
# Terminal 1 (Appetizer clone directory)
docker compose exec quickstart ziti edge login https://quickstart.127.0.0.1.nip.io:1280 \
  -u admin -p admin -y --ca /ziti/pki/root-ca/certs/root-ca.cert
docker compose exec quickstart ziti edge list terminators
```

These commands should result in a table, and one of the rows should contain `classifier-service` in the `SERVICE` column.

---

## Step 2: Add the files for this exercise

💻 In Terminal 1, from inside your appetizer clone:

```bash
# Terminal 1 (Appetizer clone directory)
git clone https://github.com/AccordionGuy/openziti-appetizer-meets-llm-gateway /tmp/oalg
cp -r /tmp/oalg/classifier /tmp/oalg/gateway .
cp /tmp/oalg/docker-compose.override.yml .
rm -rf /tmp/oalg
cp gateway/env.sh.example gateway/env.sh
```

Your appetizer directory should now look like this:

```
appetizer/
├── classifier/
│   ├── Dockerfile
│   ├── classifier.py               ← now with a second opinion
│   ├── requirements.txt
│   └── wire-up.sh
├── gateway/
│   ├── env.sh                      ← your keys go here in step 6; never commit it
│   ├── env.sh.example
│   ├── helpers.sh
│   ├── llm-gateway.yml
│   ├── tour-1-roundrobin.yml
│   └── tour-2-pool.yml
├── docker-compose.override.yml     ← three new lines in the classifier's environment
├── docker-compose.yml              ← untouched
├── overlay/
└── underlay/
```

💻 Rebuild the classifier and restart it:

```bash
# Terminal 1 (Appetizer clone directory)
unset GATEWAY_URL
docker compose build classifier
docker compose up -d classifier
```

Only the last layer of the image rebuilds, because only `classifier.py` changed, so the process should happen quickly. PyTorch and the model weights come from episode 1’s cached layers.

> Don’t add anything to `requirements.txt`. Changing it invalidates the cached layer that installs PyTorch, and the rebuild goes back to taking minutes. The new code uses only Python’s standard library for exactly that reason.

💻 Open Terminal 3 and follow the classifier’s log:

```bash
# Terminal 3 (Appetizer clone directory)
docker compose logs -f classifier
```

Wait for `binding ziti service classifier-service` to appear as part of the output.

💻 In Terminal 2, start the reflect client with episode 1’s identity:

```bash
# Terminal 2 (Appetizer clone directory)
docker run --rm -it --network appetizer_default \
  -v "$PWD":/src -w /src -v ~/.ziti-demo:/jwt \
  -v ~/.ziti-demo-gomod:/go/pkg/mod \
  golang:1.25 \
  go run clients/reflect.go local_reflectService /jwt/local_ziggy.json
```
This is the **client command**; later steps refer back to it.

After a moment of two, you should see the following:

```
INFO[0000] end to end encrypted connection to local_reflectService established 
INFO[0000] you may now type a line to be sent to the server (press enter to send) 
INFO[0000] the line will be sent to the reflect server and returned 
Enter some text to send: 
```

💻 At the`Enter some text to send:` prompt, enter:

```
nobody here wants you around and everyone knows it
```

Terminal 2 will relay it back to you like so:

```
wrote 51 bytes
connection timed out, redialing connection...
reconnected.
attempt 2 of 3
wrote 51 bytes
Sent    :nobody here wants you around and everyone knows it
Received: you sent me: nobody here wants you around and everyone knows it
```

Terminal 3 will show:

```
classifier-1  | clean by=classifier {'label': 'non-offensive', 'score': 0.8415723443031311} :: nobody here wants you around and everyone knows it
```

The only difference from exercise 1 is `by=classifier`. `by=` says who made the call, and right now, that’s always the classifier. By step 11 it will be a model that LLM Gateway picked.

---

## Step 3: Install LLM Gateway and its test backend

You need LLM Gateway **v0.1.7 or later**. Earlier versions don’t have the test backend (added in v0.1.5), and before v0.1.6, failover sent an empty body to the surviving backend, `${VAR}` references in keys were used literally, and the `model` field in responses didn’t say which model the gateway actually picked. This exercise depends on all of those.

💻 Download the release with `curl` rather than a browser. macOS quarantines files that browsers download, and `curl` skips that.

```bash
# Terminal 1 (Appetizer clone directory)
cd ~/Downloads
curl -LO https://github.com/openziti/llm-gateway/releases/download/v0.1.7/llm-gateway_0.1.7_darwin_arm64.tar.gz
tar xzf llm-gateway_0.1.7_darwin_arm64.tar.gz llm-gateway
mkdir -p ~/bin && mv llm-gateway ~/bin/
cd -
```

On an Intel Mac, use `darwin_amd64` in place of `darwin_arm64`.

💻 Make sure `~/bin` and Go’s `~/go/bin` are on your PATH, and that no older copy is hiding the new one:

```bash
# Terminal 1 (Appetizer clone directory)
echo 'export PATH="$HOME/bin:$HOME/go/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
which -a llm-gateway
llm-gateway version
```

`which -a` should list only `~/bin/llm-gateway`, and `llm-gateway version` should say `v0.1.7`.

> ### If `which -a` lists more than one
>
> The first one listed is the one that runs. A copy in `/usr/local/bin`, or one in `~/go/bin` from building the gateway from source, will quietly win if it comes first. Rename the extras rather than deleting them:
>
> ```bash
> sudo mv /usr/local/bin/llm-gateway /usr/local/bin/llm-gateway-old
> rehash
> ```

💻 Install `dummy-model`, a fake backend that ships with LLM Gateway. It isn’t in the release archives, so build it with Go:

```bash
# Terminal 1
go install github.com/openziti/llm-gateway/cmd/dummy-model@v0.1.7
which dummy-model
```

If Go complains that the module needs a newer version, put `GOTOOLCHAIN=auto` in front of the command.

💻 Install jq, which the shell helpers in step 6 use. On macOS with Homebrew:

```bash
# Terminal 1
brew install jq
```

On Linux or WSL, use your package manager instead: `sudo apt install jq` (Debian, Ubuntu, WSL), `sudo dnf install jq` (Fedora, RHEL), or `sudo pacman -S jq` (Arch). Binaries for other systems are at https://jqlang.org/download/.

Check it worked:

```bash
# Terminal 1
jq --version
```

---

## Step 4: Start Ollama and pull the models

[Ollama](https://ollama.com/) runs the local models. Run it from a terminal rather than from the menu-bar app, because it needs three settings the app doesn’t give you, and because step 13 stops it on purpose.

💻 Quit the Ollama menu-bar app if it’s running (click the llama icon, then **Quit Ollama**), then make sure nothing else holds its port:

```bash
# Terminal 5 (any directory)
lsof -nP -iTCP:11434 -sTCP:LISTEN     # should print nothing
```

The command above should produce no output.

💻 Start Ollama:

```bash
# Terminal 5 (any directory)
OLLAMA_KEEP_ALIVE=2h OLLAMA_MAX_LOADED_MODELS=3 OLLAMA_CONTEXT_LENGTH=8192 ollama serve
```

Each setting matters:

| Setting | Why |
|---|---|
| `OLLAMA_KEEP_ALIVE=2h` | Ollama unloads idle models after 5 minutes by default, and reloading one takes seconds. |
| `OLLAMA_MAX_LOADED_MODELS=3` | Every escalation uses three models: one for embeddings, one to break ties, and one to answer. They all need to stay loaded at once. |
| `OLLAMA_CONTEXT_LENGTH=8192` | On machines with lots of memory, Ollama’s default context window is enormous (262,144 tokens on the test machine), and each model reserves memory to match. A one-word verdict needs a tiny fraction of that. |

Without these settings, the test machine reloaded a model on every escalation: **8.3 seconds per call instead of 0.6.**

💻 In Terminal 1, pull the three models:

```bash
# Terminal 1 (Appetizer clone directory)
ollama pull gemma3:4b           # the general route, and the gateway's tie-breaker
ollama pull nomic-embed-text    # turns messages into embeddings for semantic routing
ollama pull gemma3:27b          # the swap target in step 12; about 17 GB
```

`gemma3:27b` takes a while. You can carry on with steps 5 to 11 while it downloads; nothing uses it until step 12.

---

## Step 5: Get a Claude API key with a spending cap

The Claude Console at [platform.claude.com](https://platform.claude.com) is where Claude API keys, billing and spending limits live. It’s separate from a Claude chat subscription.

The Console’s Default workspace can’t have its own spending limit, so you’ll make a new workspace for this exercise and cap it.

💻 In the Console:

1. Go to **Settings → Workspaces** and click **Add Workspace**. Call it `ziti-appetizer`.
2. Open the new workspace’s **Limits** tab. Set the spend limit to **$5**, and add an email notification at **$1**.
3. Go to **API keys** and create a key, making sure the workspace selector says `ziti-appetizer`. Copy it.

A dollar would actually be plenty. At the time of writing, Claude Haiku 4.5 costs $1 per million input tokens and $5 per million output tokens ([current pricing](https://platform.claude.com/docs/en/about-claude/pricing)). An escalation is about 150 tokens in and a few out, which comes to roughly $0.0002, so $5 covers about 25,000 of them. The notification at $1 is there to tell you if something is looping.

If you ever hit the cap, the API returns HTTP 400 and the classifier keeps its own verdict. Nothing breaks.

---

## Step 6: Create gateway keys and load your shell

The gateway issues its own keys, so the classifier never holds your Anthropic key.

💻 Generate two, one for the classifier and one for you:

```bash
# Terminal 1 (Appetizer clone directory)
llm-gateway genkey
llm-gateway genkey
```

These commands will produce two keys, each beginning with `sk-gw-`.

💻 Open `gateway/env.sh` in an editor and fill in all three keys: your Anthropic key from step 5, and the two `sk-gw-` keys you just generated. Never `cat` this file anywhere people can see your screen.

💻 Load the keys and the shell helpers in Terminal 1 and Terminal 4:

```bash
# Terminal 1 (Appetizer clone directory) and Terminal 4
. gateway/env.sh; . gateway/helpers.sh
type ask        # should print: ask is a shell function
```

The `.` matters. Sourcing a file runs it in your current shell. Running it with `sh`, `bash` or `./` defines the functions in a child shell that exits immediately, and you get `command not found: ask`.

`helpers.sh` defines two functions, so nobody has to type JSON:

| Function | What it sends |
|---|---|
| `ask <model> <text> [key]` | One message to the model you name. Prints the model the gateway bound, an arrow, then the reply or the error. |
| `judge <text>` | The exact request the classifier sends when it escalates: `model: "auto"`, the moderator prompt, and the classifier’s key. |

---

## Step 7: Prove step one with two fake backends

Before putting a real model behind the gateway, prove the gateway works with no OpenZiti and no real model in the picture. `dummy-model` answers every request with a canned line, which makes it obvious which backend replied.

💻 Start two of them, one per terminal:

```bash
# Terminal 6 (any directory)
dummy-model --listen 127.0.0.1:8081 --response "answered by dummy-a"
```

```bash
# Terminal 7 (any directory)
dummy-model --listen 127.0.0.1:8082 --response "answered by dummy-b"
```

💻 Look at `gateway/tour-1-roundrobin.yml`. It’s short: one provider with two endpoints, health-checked every five seconds. Start the gateway with it:

```bash
# Terminal 4 (Appetizer clone directory)
llm-gateway run gateway/tour-1-roundrobin.yml
```

Wait for `listening on '127.0.0.1:8080'`.

💻 Send four requests:

```bash
# Terminal 1 (Appetizer clone directory)
for i in 1 2 3 4; do ask dummy hi; done
```

You should see output that looks like this:


```
dummy → answered by dummy-a
dummy → answered by dummy-b
dummy → answered by dummy-a
dummy → answered by dummy-b
```

That’s round-robin: each request goes to the next endpoint in the pool.

💻 Now kill dummy-b with **Ctrl-C** in Terminal 7, and send four more:

```bash
# Terminal 1 (Appetizer clone directory)
for i in 1 2 3 4; do ask dummy hi; done
```

Every reply now comes from dummy-a, with no errors, and Terminal 4 logs:

```
endpoint 'dummy-b' is now unhealthy
```

The gateway saw a connection fail, marked the endpoint unhealthy, and retried the request on dummy-a. **Network errors fail over. Bad requests don’t.** A 400 or a model-not-found goes straight back to the caller, because sending the same bad request to another backend would get the same answer.

💻 Restart dummy-b in Terminal 7 (the same command as before)...

```bash
# Terminal 7 (any directory)
dummy-model --listen 127.0.0.1:8082 --response "answered by dummy-b"
```

💻 ...then rerun the loop every 15 seconds or so. 

```bash
# Terminal 1 (Appetizer clone directory)
for i in 1 2 3 4; do ask dummy hi; done
```

Within about a minute, Terminal 4 logs `endpoint 'dummy-b' is now healthy` and the alternation returns. It takes a while because the gateway backs off its health checks after repeated failures, so a flapping backend doesn’t get hammered.

---

## Step 8: A pool is copies, not choices

What happens if the endpoints in a pool don’t have the same models?

💻 Stop the gateway with **Ctrl-C** in Terminal 4. Look at `gateway/tour-2-pool.yml`: the pool now holds Ollama and dummy-a. Start the gateway with it:

```bash
# Terminal 4 (Appetizer clone directory)
llm-gateway run gateway/tour-2-pool.yml
```

💻 Ask for a model only Ollama has:

```bash
# Terminal 1 (Appetizer clone directory)
for i in 1 2 3 4; do ask gemma3:4b "say hi in five words"; done
```

You should see this output:

```
gemma3:4b → Hello, how are you today?
gemma3:4b → answered by dummy-a
gemma3:4b → Hello, how are you today?
gemma3:4b → answered by dummy-a
```

You asked for `gemma3:4b` every time, and half the answers came from a box that doesn’t have it. The gateway labels both as `gemma3:4b`, because the `model` field reports the model the gateway selected, not what the backend did with it.

Endpoints in a pool are copies of each other, and the gateway doesn’t check who has what. To send different requests to different models, you name the model, and the model’s name picks the provider. That’s what routes do, and it’s the rest of this exercise.

> If you see `error → model 'gemma3:4b' not found` alternating with dummy-a, Ollama doesn’t have the model yet; go back to step 4. That output is instructive too: Ollama’s 404 came straight back to you instead of failing over to dummy-a.

💻 Stop both dummies with **Ctrl-C** in Terminals 6 and 7. Nothing after this uses them.

---

## Step 9: Virtual API keys

From here on, the gateway runs with `gateway/llm-gateway.yml`. Open it and look at the top two blocks:

- **`providers`** has Ollama and Anthropic. Your Anthropic key appears only as `${ANTHROPIC_API_KEY}`, read from Terminal 4’s environment.
- **`api_keys`** turns on virtual keys. The classifier’s key may use `gemma3:*` and `claude-haiku-4-5-*` models, and only the `general` and `subtle` routes. Your key is unrestricted.

💻 Stop the gateway with **Ctrl-C** in Terminal 4 and start it with the full config:

```bash
# Terminal 4 (Appetizer clone directory)
source gateway/env.sh
llm-gateway run gateway/llm-gateway.yml
```

The first start takes several seconds, because the gateway turns every route example into an embedding before it starts listening. Later restarts are almost instant, because Ollama keeps the embedding model loaded.

> If the gateway exits naming a `${VAR}`, you haven’t sourced `gateway/env.sh` in Terminal 4, or one of its keys is empty. It refuses to start rather than use an empty key.

💻 Try four requests:

```bash
# Terminal 1 (Appetizer clone directory)
ask gemma3:4b hi
ask gemma3:4b hi "$CLASSIFIER_GATEWAY_KEY"
ask claude-opus-5-5 hi "$CLASSIFIER_GATEWAY_KEY"
ask claude-haiku-4-5-20251001 "say hi" "$CLASSIFIER_GATEWAY_KEY"
```

You should see output that looks like this:

```
error → API key required
gemma3:4b → Hi there! How’s your day going so far? Is there anything you’d like to chat about, or were you just saying hello?
error → model 'claude-opus-5-5' is not allowed for this API key
claude-haiku-4-5-20251001 → Hi! 👋 How can I help you today?
```

No key gets no service. The classifier’s key gets gemma. It can’t spend your money on Opus, and Terminal 4 says so:

```
key 'classifier' denied access to model 'claude-opus-5-5'
```

That refusal happened before anything left your machine. And Claude answered a request from a caller that has never held the Anthropic key.

> One gap: LLM Gateway doesn’t have per-key spending limits yet. That’s why the cap lives in the Claude Console workspace from step 5.

---

## Step 10: Semantic routing

Look at the `routing` block at the bottom of `gateway/llm-gateway.yml`. There are two routes:

- **`general`**, for everyday messages, goes to `gemma3:4b` on your machine.
- **`subtle`**, for messages that exclude, silence or belittle someone without insults or profanity, goes to Claude.

Each route has five example phrases. None of them is a phrase you’ll test with; that would be cheating.

When a request asks for `model: "auto"`, the gateway routes it in three layers:

1. **Embeddings.** It turns the last user message into an embedding with `nomic-embed-text` and scores it against every route’s examples. `comparison: max` means a message scores against its closest example, rather than the average of all of them. A score of 0.85 or more is a match.
2. **Tie-breaker.** A score between 0.65 and 0.85 is ambiguous, so `gemma3:4b` reads the message and the route descriptions and picks one.
3. **Default.** Below 0.65 is no match, and the message goes to `default_route`, which is `general`.

Only the **last user message** is embedded. That’s why the classifier puts its instructions in the system message and the text being judged, alone, in the user message.

💻 Send the classifier’s exact request for three phrases:

```bash
# Terminal 1 (Appetizer clone directory)
judge "you are a delight"
judge "nobody here wants you around and everyone knows it"
judge "people like you should not be allowed to speak"
```

```
gemma3:4b → CLEAN
claude-haiku-4-5-20251001 → OFFENSIVE
claude-haiku-4-5-20251001 → OFFENSIVE
```

💻 Now read Terminal 4. line starts with a timestamp and the gateway's function name, followed by `semantic routing:`. Look at the endings of the most recent lines in the log, which should look like this:

```
semantic routing: key='classifier' method=default route='general' model='gemma3:4b' confidence=0.00 latency=45ms cascade=[semantic:general:0.51:no_match,default:general]
semantic routing: key='classifier' method=classifier route='subtle' model='claude-haiku-4-5-20251001' confidence=0.95 latency=324ms cascade=[semantic:subtle:0.68:ambiguous,classifier:subtle:0.95]
semantic routing: key='classifier' method=classifier route='subtle' model='claude-haiku-4-5-20251001' confidence=0.95 latency=368ms cascade=[semantic:subtle:0.69:ambiguous,classifier:subtle:0.95]
```

Three phrases took three different paths through the router:

| Phrase | What happened |
|---|---|
| you are a delight | Closest example scored 0.51, below the 0.65 floor, so no match. It took the default route to gemma. |
| nobody here wants you around and everyone knows it | Scored 0.68 for subtle: ambiguous. The tie-breaker picked subtle with 0.95 confidence, so it went to Claude. |
| people like you should not be allowed to speak | Scored 0.69 for subtle, the same story. |

Your numbers may differ a little. If a subtle phrase lands in `general` on your machine, lower `threshold` slightly, or add another example to the `subtle` route that isn’t one of your test phrases. Restart the gateway after every change to the file.

---

## Step 11: Give the classifier a second opinion

Everything so far has been the gateway on its own. Now the classifier starts using it.

### What changed in `classifier.py`

The escalation rule is four lines in `classify()`:

```python
if GATEWAY_URL and not offensive and score < ESCALATE_BELOW:
    opinion = second_opinion(text)
    if opinion is not None:
        offensive, decided_by = opinion
```

Only verdicts the classifier calls clean with less than 90% confidence escalate. A confident “offensive” stands, and profanity never gets this far, because the Appetizer’s own filter rejects it first.

`second_opinion()` sends the same request `judge` does, with three choices worth noticing:

- **`"model": "auto"`.** The classifier doesn’t pick a model. It doesn’t even know Claude exists.
- **`"max_tokens": 5`.** The answer is one word, and the cap also bounds what a single call can cost. Without it, LLM Gateway asks Anthropic for up to 4,096 tokens.
- **Any failure returns `None`,** and the classifier keeps its own verdict. That covers a gateway that isn’t running, a backend that’s down, a refused key and a spent budget.

> ### Why the gateway call doesn’t use `urllib`
>
> The classifier runs inside `openziti.zitify`, which swaps out Python’s socket functions so the web server’s bind becomes an OpenZiti service bind. In openziti 1.7.1, the replacement `socket.create_connection` handles ordinary, non-OpenZiti connections by falling back to a plain socket, but it creates that socket with the wrong address family. An ordinary `urllib` request to the gateway fails with:
>
> ```
> a bytes-like object is required, not 'tuple'
> ```
>
> The workaround is two lines. The file saves the original `socket.create_connection` at import time, before zitify runs, and `second_opinion()` hands it to an `http.client.HTTPConnection`. If you make other outbound HTTP calls from inside `zitify`, you’ll need the same trick.

### Switch it on

The switch is one environment variable. Compose reads it, along with the classifier’s gateway key, from the shell that runs `docker compose up`.

💻 In Terminal 1:

```bash
# Terminal 1 (Appetizer clone directory)
. gateway/env.sh
export GATEWAY_URL=http://host.docker.internal:8080
docker compose up -d classifier
docker compose exec classifier printenv GATEWAY_URL     # http://host.docker.internal:8080
```

`host.docker.internal` is how a container reaches your Mac. Docker Desktop defines it.

💻 Recreating the container ended Terminal 3’s log stream, so start it again:

```bash
# Terminal 3 (Appetizer clone directory)
docker compose logs -f classifier
```

Wait for `binding ziti service classifier-service`.

💻 In Terminal 2, send these five messages, one at a time, and watch Terminals 3 and 4 after each:

| Send | Terminal 2 | Terminal 3 |
|---|---|---|
| `you are a delight` | relayed | `clean by=gemma3:4b` |
| `nobody here wants you around and everyone knows it` | not relayed | `OFFENSIVE by=claude-haiku-4-5-20251001` |
| `people like you should not be allowed to speak` | not relayed | `OFFENSIVE by=claude-haiku-4-5-20251001` |
| `you are too stupid to understand this` | not relayed | `OFFENSIVE by=classifier` |
| the English swear word of your choice | rejected by the Appetizer | nothing |

Here’s the second one, the message that sailed through in step 2:

```
classifier-1  | OFFENSIVE by=claude-haiku-4-5-20251001 {'label': 'non-offensive', 'score': 0.8415723443031311} :: nobody here wants you around and everyone knows it
```

The classifier’s own label is still `non-offensive`, at 0.84. Because that’s under 0.9, it asked, and Claude disagreed.

Every message took a different path:

- **“you are a delight”** escalated, because the classifier was only 88% sure, and the gateway sent it to the local model.
- **The two subtle ones** escalated, and the gateway sent them to Claude.
- **“you are too stupid…”** never escalated. The classifier was confident, so no LLM was asked and nothing was spent.
- **The swear word** never reached the classifier at all. The silence in Terminal 3 is the evidence.

**The app decided whether to ask an LLM. The gateway decided which one answered.**

---

## Step 12: Swap the model behind the route

Suppose your security team rules that user messages can’t go to a third-party API. With the gateway in place, that’s one line in one file.

💻 Change the `subtle` route’s model from Claude to the big local model:

```bash
# Terminal 1 (Appetizer clone directory)
sed -i '' 's#model: claude-haiku-4-5-20251001#model: "gemma3:27b"#' gateway/llm-gateway.yml
grep -n 'gemma3:27b' gateway/llm-gateway.yml
```

If you’d rather edit the file by hand, keep the quotes around `"gemma3:27b"`, and type `model: "gemma3:27b"` exactly. A stray space after the colon, as in `gemma3: 27b`, gives you `mapping values are not allowed in this context` when the gateway starts.

💻 Restart the gateway with **Ctrl-C** in Terminal 4, then:

```bash
# Terminal 4 (Appetizer clone directory)
llm-gateway run gateway/llm-gateway.yml
```

💻 In Terminal 2, resend:

```
nobody here wants you around and everyone knows it
```

It’s still blocked. Terminal 4 logs `route='subtle' model='gemma3:27b'`, and Terminal 3 shows:

```
classifier-1  | OFFENSIVE by=gemma3:27b {'label': 'non-offensive', 'score': 0.8415723443031311} :: nobody here wants you around and everyone knows it
```

The classifier didn’t change. The Appetizer didn’t change. The classifier asked for a route, not a model, so whoever runs the gateway can move that route anywhere.

💻 Time it, twice, so the second run has the model loaded:

```bash
# Terminal 1 (Appetizer clone directory)
time (judge "nobody here wants you around and everyone knows it")
time (judge "nobody here wants you around and everyone knows it")
```

The parentheses matter in zsh, which prints no timing for a shell function that runs in the current shell. On the test machine, the warm local model took **0.62 seconds**, and Claude took **1.32**. Moving in-house kept the verdict and was faster, because the round trip to the cloud went away. Your numbers will depend on your hardware.

💻 Put Claude back when you’re done:

```bash
# Terminal 1 (Appetizer clone directory)
sed -i '' 's#model: "gemma3:27b"#model: claude-haiku-4-5-20251001#' gateway/llm-gateway.yml
```

💻 Then restart the gateway in Terminal 4:

```bash
# Terminal 4
llm-gateway run gateway/llm-gateway.yml
```

---

## Step 13: Take the backend away

💻 Stop Ollama with **Ctrl-C** in Terminal 5. Then, in Terminal 2, resend:

```
nobody here wants you around and everyone knows it
```

This time it’s relayed, and Terminal 3 shows why:

```
classifier-1  | escalation refused (500): {"error":{"message":"request failed: Post \"http://127.0.0.1:11434/v1/chat/completions\": dial tcp 127.0.0.1:11434: connect: connection refused","type":"server_error"}}
classifier-1  | clean by=classifier {'label': 'non-offensive', 'score': 0.8415723443031311} :: nobody here wants you around and everyone knows it
```

The gateway couldn’t get an answer, so the classifier kept its own verdict. That’s degraded, not down, and it’s the same fail-open choice the Appetizer made in episode 1. It’s the application’s choice, not the network’s.

Terminal 4 shows something worth knowing:

```
embedding match error: failed to embed prompt: request failed: Post "http://127.0.0.1:11434/api/embed": dial tcp 127.0.0.1:11434: connect: connection refused
semantic routing: key='classifier' method=default route='general' model='gemma3:4b' confidence=0.00 latency=0ms cascade=[semantic:error,default:general]
provider error: request failed: Post "http://127.0.0.1:11434/v1/chat/completions": dial tcp 127.0.0.1:11434: connect: connection refused
```

The embeddings run on Ollama too, so the router couldn’t embed the message. It fell back to its default route, and that route also lives on Ollama. The request never got as far as Claude, even though Claude was available the whole time. Worth knowing before you put one box under everything.

💻 Start Ollama again in Terminal 5:

```bash
OLLAMA_KEEP_ALIVE=2h OLLAMA_MAX_LOADED_MODELS=3 OLLAMA_CONTEXT_LENGTH=8192 ollama serve
```

The models reload on their first use.

---

## Applying this to your own application

The classifier and the Appetizer are stand-ins. The pattern works for anything that sometimes needs an LLM.

**Keep the “whether” in your app.** Your code knows when a cheap, deterministic answer is good enough. Here it was four lines and a confidence threshold. Most requests never leaving your process is the biggest saving you’ll get.

**Hand the “which” to the gateway.** Ask for `auto`, or for a route, rather than a vendor’s model name. Then changing models, providers or policies is a config change that whoever runs the gateway can make, as step 12 showed.

**Give every caller its own virtual key.** Restrict it to the models and routes that caller needs. The real provider keys live in one place, and a leaked caller key can’t reach the expensive models.

**Write route examples that describe categories, not test cases,** and read the `cascade=[…]` log lines to see why each message went where it did.

**Plan for failure, and know what shares a box.** The classifier’s fallback kept the app working in step 13. That step also showed that the embeddings and the default route both depended on the same Ollama instance.

Next steps:

- LLM Gateway: https://github.com/openziti/llm-gateway, with docs at https://netfoundry.io/docs/llm-gateway
- Episode 1 of this series: https://github.com/AccordionGuy/openziti-appetizer-classifier
- OpenZiti Python SDK: https://github.com/openziti/ziti-sdk-py
- Community: https://openziti.discourse.group/

Coming next: the model stops answering questions and starts choosing what to do. It gets tools that are dark services on the overlay, and OpenZiti’s service policies decide which tools it may reach.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `command not found: ask` | `helpers.sh` isn’t loaded in this terminal, or it was run instead of sourced | `. gateway/helpers.sh` |
| `bind: address already in use` on 8080, 8081 or 8082 | An earlier gateway or dummy-model is still running, possibly in another terminal | `lsof -nP -iTCP:8080 -sTCP:LISTEN`, then Ctrl-C it, or `pkill -f "llm-gateway run"` and `pkill dummy-model` |
| `llm-gateway version` shows an older version | An older copy comes first in your PATH | `which -a llm-gateway`, then rename the extras |
| The gateway exits naming a `${VAR}` | `gateway/env.sh` isn’t sourced in Terminal 4, or a key in it is empty | Fill in the key and `. gateway/env.sh` |
| `mapping values are not allowed in this context` | A stray `: ` in a YAML edit, often `gemma3: 27b` | Quote the value: `model: "gemma3:27b"` |
| `error → model '…' not found` | The model isn’t pulled, or its name is misspelled. The gateway doesn’t check model names at startup | `ollama list`, then `ollama pull <model>` |
| Escalations take many seconds each | Ollama is unloading and reloading models | Start Ollama with the step 4 settings. `ollama ps` should list all three models with about 2 hours left |
| `escalation failed … a bytes-like object is required, not 'tuple'` | Outbound `urllib` inside `zitify`; you’re running episode 1’s `classifier.py` or your own code | Use this repo’s `classifier.py` and rebuild. See step 11 |
| `escalation failed … Connection refused` | The gateway isn’t running, or the container can’t reach it | Start the gateway. Check `docker compose exec classifier printenv GATEWAY_URL`. On Linux, see below |
| `escalation refused (401)` | `CLASSIFIER_GATEWAY_KEY` wasn’t set in the shell that ran `docker compose up` | `. gateway/env.sh`, then `docker compose up -d classifier` |
| `escalation refused (403)` | The route’s model isn’t in the classifier key’s `allowed_models` | Widen `allowed_models`, or route to a model it already allows |
| `escalation refused (400)` mentioning workspace usage limits | The Console spending cap was reached | Raise it in the Console, or route to a local model |
| Terminal 3 shows `by=classifier` for every message | `GATEWAY_URL` wasn’t set when the container was created | Export it and run `docker compose up -d classifier`. `restart` keeps the old environment |
| Terminal 3’s lines have no `by=` at all | The container is running the old image | `docker compose build classifier`, then `docker compose up -d classifier` |
| Every request routes to `general` with `confidence=0.00` | Thresholds too strict for your examples, or the classifier layer is off. In testing, turning that layer off changed the semantic scores | Keep `classifier.enabled: true`, and lower `threshold` a little |
| The reflect client says `no edge routers connected in time` | The `router` container stopped | See the callout in step 1 |
| `docker compose build` hangs at `load metadata for docker.io/library/python:3.12-slim` | Docker can’t reach Docker Hub, often because of a stuck credential helper | Ctrl-C, run `docker pull python:3.12-slim`, and restart Docker Desktop if that hangs too |
| `time judge …` prints no timing | zsh doesn’t time shell functions that run in the current shell | `time (judge "…")` |
| `the cached access token has expired` from `ziti` | The admin session from step 1 timed out | Run the `ziti edge login` command from step 1 again |
| dummy-b doesn’t rejoin | Health checks back off after repeated failures | Wait up to a minute |
| `exited with code 137` in the classifier log | `docker compose restart` force-stops containers that take more than 10 seconds to stop | Harmless |
| `llm-gateway` crashes on launch with a SIGSEGV mentioning `go-m1cpu` | The macOS build includes go-m1cpu v0.1.6, which has crashed other OpenZiti Go tools on some Apple Silicon chips. It ran fine on the test machine | Run a Linux build in Docker, as below |

### If the gateway crashes on your Mac

go-m1cpu only runs on macOS, so a Linux build of the gateway in a container avoids the crash. This fallback hasn’t been tested end to end.

```bash
# Terminal 1 (Appetizer clone directory), from your appetizer clone. One-time: build a Linux binary
docker run --rm -v "$PWD/gateway/bin":/go/bin golang:1.26 \
  go install github.com/openziti/llm-gateway/cmd/llm-gateway@v0.1.7

# One-time: copies of the configs that listen inside the container and reach your Mac
for f in tour-1-roundrobin tour-2-pool llm-gateway; do
  sed -e 's#"127.0.0.1:8080"#"0.0.0.0:8080"#' -e 's#http://127.0.0.1:#http://host.docker.internal:#' \
    "gateway/$f.yml" > "gateway/$f.docker.yml"
done
```

```bash
# Terminal 4 (Appetizer clone directory), in place of every `llm-gateway run gateway/<name>.yml`
docker run --rm -it -p 127.0.0.1:8080:8080 -v "$PWD/gateway":/cfg \
  -e ANTHROPIC_API_KEY -e CLASSIFIER_GATEWAY_KEY -e MY_GATEWAY_KEY \
  golang:1.26 /cfg/bin/llm-gateway run /cfg/llm-gateway.docker.yml
```

The port is published on your Mac’s loopback, so `ask`, `judge` and the classifier reach it at the same addresses as before.

---

## Running on Linux

This exercise was written and tested on macOS. On Linux, three things differ. These changes haven’t been tested.

1. **Containers can’t reach `127.0.0.1` on the host.** Make the gateway listen on the Docker bridge address instead, usually `172.17.0.1` (check with `ip addr show docker0`). In `gateway/llm-gateway.yml`, set `listen: "172.17.0.1:8080"`, and before sourcing the helpers, run `export GATEWAY=172.17.0.1:8080`. A host firewall such as ufw may need to allow traffic from Docker’s bridge.
2. **`host.docker.internal` isn’t defined.** Uncomment the `extra_hosts` lines in `docker-compose.override.yml`. They map the name to the same bridge address.
3. **Commands differ slightly.** Download the `linux_amd64` or `linux_arm64` archive in step 3. GNU `sed` takes `-i` with no `''` after it, so drop the `''` in steps 12 and 13. In bash, use `hash -r` where this README says `rehash`.

---

## Reset

💻 To put the classifier back the way episode 1 left it:

1. Stop the gateway with **Ctrl-C** in Terminal 4, and Ollama with **Ctrl-C** in Terminal 5.
2. Switch off escalation:

    ```bash
    # Terminal 1 (Appetizer clone directory)
    unset GATEWAY_URL
    docker compose up -d classifier
    ```

3. In the Claude Console, archive the `ziti-appetizer` workspace when you no longer need it. Archiving a workspace revokes its keys.
4. Delete `gateway/env.sh`, which holds your keys.

To reset everything, including episode 1’s network and identities, follow the [Reset section of the episode 1 README](https://github.com/AccordionGuy/openziti-appetizer-classifier#reset).

---

## Credits

Built on the [OpenZiti Appetizer](https://github.com/openziti-test-kitchen/appetizer) and [LLM Gateway](https://github.com/openziti/llm-gateway). OpenZiti is an open-source zero-trust networking platform created and sponsored by NetFoundry, and both projects are licensed Apache 2.0. Made for Ziti TV.