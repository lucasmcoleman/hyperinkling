FROM nvidia/cuda:12.8.1-devel-ubuntu24.04 AS build

ARG HYPERINKLING_MODE=stable
ARG CUDA_ARCHITECTURES=86
ARG BUILD_JOBS=2

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates cmake g++ git ninja-build \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/hyperinkling
COPY scripts/fetch-source.sh scripts/fetch-source.sh
COPY patches/ patches/

RUN bash scripts/fetch-source.sh "$HYPERINKLING_MODE" /opt/maya/source \
    && git init -q /opt/llama.cpp \
    && git -C /opt/llama.cpp fetch --no-tags --depth=1 https://github.com/ggml-org/llama.cpp.git 3cf03257f219afbe7334045ff7c6a06ac68c627d \
    && git -C /opt/llama.cpp -c advice.detachedHead=false checkout -q --detach FETCH_HEAD \
    && cmake -S /opt/maya/source -B /tmp/maya-build -G Ninja \
       -DCMAKE_BUILD_TYPE=Release -DSTRATA_ENABLE_CUDA=ON \
       -DSTRATA_BUILD_TESTS=OFF "-DCMAKE_CUDA_ARCHITECTURES=$CUDA_ARCHITECTURES" \
       -DSTRATA_GGML_DIR=/opt/llama.cpp \
    && cmake --build /tmp/maya-build --target maya-ik2 --parallel "$BUILD_JOBS" \
    && install -Dm0755 /tmp/maya-build/maya-ik2 /opt/maya/bin/maya-ik2 \
    && rm -rf /opt/maya/source/.git

# The fetch script creates its checkout in a private staging directory.
RUN chmod a+rx /opt/maya/source

FROM nvidia/cuda:12.8.1-runtime-ubuntu24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libgomp1 python3 python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/venv \
    && useradd --create-home --uid 10001 --shell /usr/sbin/nologin maya

COPY requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

COPY --from=build /opt/maya/ /opt/maya/
COPY profiles/ /opt/maya/profiles/
COPY licenses/ /opt/maya/licenses/

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    MAYA_SERVER_LOG=0 \
    MAYA_UPDATE_CHECK=0

WORKDIR /opt/maya/source
USER maya
EXPOSE 8080
ENTRYPOINT ["python", "serve/server.py", "--engine", "maya", "--host", "0.0.0.0", "--port", "8080", "--config"]
CMD ["/opt/maya/profiles/64k-fp8.json"]
