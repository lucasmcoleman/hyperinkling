# HyperInkling

Serve [Inkling 2 Mini](https://huggingface.co/thinkingmachines/Inkling-2-Mini) on an NVIDIA RTX 3090 with a text API. HyperInkling adds a mainline GGUF loader patch to the Maya IK2 CUDA engine and packages it with the Maya HTTP server and ready-to-run profiles. The default runs one request at a time with 64K FP8 KV and queues additional callers. A long-context profile raises that to 196,608 tokens on the same GPU with every expert still resident in VRAM.

The project was inspired by [HyperQwen](https://github.com/syv-ai/HyperQwen), which showed how much a carefully tuned serving stack can speed up a model on a single consumer GPU. HyperInkling applies the same idea to Inkling 2 Mini.

## Quick start

Run the commands from the repository root in a Linux shell. You need an x86-64 Linux host or WSL 2, Docker with NVIDIA GPU access, and the Hugging Face CLI (`hf`) for model acquisition. The build needs internet access to fetch source and dependencies. Plan for at least 17 GB of model storage, plus room for the build and container layers. The reference GPU is a 24 GB RTX 3090 (compute capability 8.6). Available VRAM matters for weights, context, and active requests.

### 1. Build the stable image

```bash
docker build --platform linux/amd64 -t hyperinkling:stable .
```

The Dockerfile compiles `maya-ik2` for SM86 with CUDA 12.8.1. The build needs the CUDA toolkit but can run without an attached GPU. To target another supported architecture or change build parallelism, pass `--build-arg CUDA_ARCHITECTURES=<architecture>` or `--build-arg BUILD_JOBS=<jobs>`.

### 2. Get the mainline GGUF and extract its tokenizer

```bash
mkdir -p models assets
hf download unsloth/Inkling-2-Mini-GGUF \
  Mainline_Support/Inkling-2-Mini-UD-Q4_K_M.gguf_file \
  --revision 45fd08764f2b0bf16b03a5483a80e5c7aaec8772 --local-dir models
mv -- models/Mainline_Support/Inkling-2-Mini-UD-Q4_K_M.gguf_file \
  models/Inkling-2-Mini-UD-Q4_K_M.gguf
(cd models && sha256sum --check --ignore-missing ../models.sha256)
```

Use the file in `Mainline_Support`. The similarly named GGUF in the root of the publisher's repository has a different layout and hash. The checksum manifest also covers the optional draft model.

```bash
docker run --rm --entrypoint python \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,source=$PWD/models,target=/models,readonly" \
  --mount "type=bind,source=$PWD/assets,target=/assets" \
  hyperinkling:stable tools/strata_tokenizer.py \
  --gguf /models/Inkling-2-Mini-UD-Q4_K_M.gguf --out /assets \
  --chat-template tools/ik2/chat_template.jinja --check
```

This reads GGUF metadata, uses Maya's inference chat template, and writes `assets/tokenizer/`. Keep the model and generated assets readable by the runtime user (UID 10001 in the image).

### 3. Start the server

```bash
docker run --rm --gpus all -p 127.0.0.1:8080:8080 \
  --mount "type=bind,source=$PWD/models,target=/models,readonly" \
  --mount "type=bind,source=$PWD/assets,target=/assets,readonly" \
  hyperinkling:stable
```

Once the engine is ready, check it and send a request from another terminal. Stop the foreground server with Ctrl+C.

```bash
curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1:8080/v1/models
curl -fsS http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' --data-binary @examples/chat.json
```

## Profiles

Pass the profile's path after the image name to override its default, for example `hyperinkling:stable /opt/maya/profiles/8k-f16.json`. To use your own config, bind-mount it read-only and pass its path inside the container. Use container paths for the executable, working directory, tokenizer, and models in the JSON.

| Profile in `/opt/maya/profiles/` | Context | Settings |
| --- | ---: | --- |
| [`64k-fp8.json`](profiles/64k-fp8.json) | 65,536 | Default. One active request, FP8 KV, 4,096-token prefill chunks. |
| [`192k-fp8.json`](profiles/192k-fp8.json) | 196,608 | Long context. Same settings as the default: one active request, FP8 KV, 4,096-token prefill chunks. |
| [`64k-fp8-dspark.json`](profiles/64k-fp8-dspark.json) | 65,536 | Optional speculative decoding with FP8 KV, adaptive draft width up to 7, and the engine's default prefill chunk. |
| [`8k-f16.json`](profiles/8k-f16.json) | 8,192 | One active request and FP16 KV. |
| [`experimental-4x32k-fp8.json`](profiles/experimental-4x32k-fp8.json) | 32,768 per slot | Four slots, FP8 KV and 2,048-token prefill chunks. Requires the experimental build. |

The context budget is shared by the rendered prompt and generated answer. Lower `--max-context` to leave more VRAM available.

The 196,608-token profile was measured on the reference RTX 3090 with one request. A 186,777-token prompt with marker codes at its start and midpoint ran in 107 seconds of prefill (about 1,750 tokens/s). The model returned both markers, and VRAM peaked at 23,087 MiB, leaving about 0.9 GB free. 262,144 tokens started but ran out of VRAM on the same long-prompt run, so 196,608 is the largest size that passed. It is not a proven maximum: sizes between the two were not tried. Anything else on the GPU, such as a desktop session, reduces the headroom.

For DSpark, download the official drafter and run the stable image with the DSpark profile.

```bash
hf download thinkingmachines/Inkling-2-Mini mtp.safetensors \
  --revision b85c3cfa615fc413cc9af3379f491b963f3b586a --local-dir models
(cd models && sha256sum --check ../models.sha256)
```

DSpark's speed depends on the workload. It helped some code and copy-heavy generations in project testing, was slower on some prose, and can produce different output from plain greedy decoding.

## API

The packaged service uses Maya's HTTP frontend. Use the advertised model ID, `inkling-2-mini`, with the OpenAI-compatible chat completions endpoint. Set `"stream": true` for server-sent events and use `curl -N` to see events as they arrive. For Inkling's reasoning controls, pass `chat_template_kwargs.reasoning_effort` as `none`, `low`, `medium`, or `high`. Reasoning tokens consume output budget when the model generates them. The profiles here are text-only. The pinned upstream guide documents Maya's other API surfaces and separate vision setup.

## Source and build layout

1. [`fetch-source.sh`](scripts/fetch-source.sh) checks out [Maya's public revision](https://github.com/alesha-pro/maya-inkling-mini/tree/e819852f822479af783638a467bfdfe2ed6882ec) and applies the [mainline GGUF loader patch](patches/0001-mainline-gguf.patch). The patch maps mainline metadata and tensor names to Maya's layer visits, reads the per-block controller queries from the mainline layout, and validates each expert matrix against its own input width.
2. The build compiles Maya's CUDA kernels and engine. The engine owns token generation, per-visit KV, and optional speculative decoding. The build uses [Maya's pinned ggml source](https://github.com/ggml-org/llama.cpp/tree/3cf03257f219afbe7334045ff7c6a06ac68c627d).
3. Maya's Python server renders the chat template, tokenizes the prompt, exchanges data with the engine over subprocess pipes, and streams the decoded response over HTTP.

This repository contains the source changes as patches, the build, profiles, and tests. The build fetches the upstream engine and server at immutable revisions. The runtime reads user-supplied weights and generated tokenizer files from mounted directories.

For a native build, use CMake 3.24+, a C++20 compiler, Ninja, and a CUDA toolkit, and configure a Maya checkout prepared by the fetch script. Run the server from the prepared checkout with a profile adapted to your native paths.

```bash
bash scripts/fetch-source.sh stable build/maya
cmake -S build/maya -B build/native -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DSTRATA_ENABLE_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=86 -DSTRATA_BUILD_TESTS=OFF
cmake --build build/native --target maya-ik2 --parallel 2
```

## Experimental batching

```bash
docker build --platform linux/amd64 --build-arg HYPERINKLING_MODE=batching \
  -t hyperinkling:batching .
```

Use the same mounts as the stable server and choose `hyperinkling:batching /opt/maya/profiles/experimental-4x32k-fp8.json`. The [batching patch](patches/0002-experimental-batched-serving.patch) adds the multi-request engine protocol and per-request cache, sampler, and cancellation state. It batches decode rows when active requests overlap and interleaves chunks of prefill. The engine accepts up to eight slots, subject to VRAM. The multi-request path requires a single GPU with resident experts. DSpark is a single-request option.

The included batch profile is for evaluation. The mixed-request parity, latency, throughput, and soak acceptance checks remain incomplete. GPU memory usage rises with both slot count and context. Batched configurations above 32K per slot, and any single-request context above 196,608 tokens, are outside the measured baseline for this project. Use the stable image and default profile to switch back from an experiment.

## Tests

The offline tests need Python 3.10+ with `venv` (the `python3-venv` package on Debian and Ubuntu), a C++20 compiler, and GNU coreutils. Setup fetches source and Python dependencies. The test run uses synthetic fixtures without model files, CUDA, or a GPU.

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
bash scripts/fetch-source.sh stable build/maya-stable
bash scripts/fetch-source.sh batching build/maya-batching
PYTHON="$PWD/.venv/bin/python" bash scripts/test-offline.sh stable build/maya-stable
PYTHON="$PWD/.venv/bin/python" bash scripts/test-offline.sh batching build/maya-batching
```

The suite checks profile contracts, Inkling chat rendering and response parsing, and the launcher's parallel flag. The batching suite also compiles the CPU serve loop tests and checks queue order, per-request cancellation, and a STOP arriving during the final prefill read. For model parity and GPU performance, run the stable and experimental images separately with temperature zero. Record the model checksum, GPU, driver, profile, returned tokens, aggregate throughput, and per-request latency.

## Security and contributions

The examples publish the API to host loopback. Keep it on a trusted machine, and use an authenticated TLS proxy for any remote access. Maya reads its optional API key from `MAYA_API_KEY`; pass it as a runtime environment variable. Keep keys, weights, generated tokenizer files, and request traces out of commits. The image runs as an unprivileged user, mounts the model and tokenizer read-only for serving, and disables upstream update checks.

For changes, run the offline tests and include the exact profile and source version when reporting runtime behavior. Synthetic prompts are sufficient for most bug reports. If reporting a security issue, use GitHub's private vulnerability reporting when enabled and keep exploit details and credentials out of public issues.

## License and credits

HyperInkling is named after, and inspired by, [HyperQwen](https://github.com/syv-ai/HyperQwen) from syv-ai. It does not include HyperQwen code.

Maya, Project Maya, Strata, and ggml retain their upstream copyright and terms. The upstream model and quantization are supplied by Thinking Machines Lab and Unsloth. See the [third-party notices](licenses/README.md) for source attribution and license scope.
