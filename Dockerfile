# syntax=docker/dockerfile:1
ARG UBUNTU_VERSION=22.04
ARG NVIDIA_CUDA_VERSION=11.8.0
# CUDA architectures, required by Colmap and tiny-cuda-nn. Use >= 8.0 for faster TCNN.
ARG CUDA_ARCHITECTURES="90;89;86;80;75;70;61"
ARG NERFSTUDIO_VERSION=""

# Pull source either provided or from git.
FROM scratch as source_copy
ONBUILD COPY . /tmp/nerfstudio
FROM alpine/git as source_no_copy
ARG NERFSTUDIO_VERSION
ONBUILD RUN git clone --branch ${NERFSTUDIO_VERSION} --recursive https://github.com/nerfstudio-project/nerfstudio.git /tmp/nerfstudio
ARG NERFSTUDIO_VERSION
FROM source_${NERFSTUDIO_VERSION:+no_}copy as source

FROM ghcr.io/kmu-fmcl/cuda:${NVIDIA_CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} as builder
ARG CUDA_ARCHITECTURES
ARG NVIDIA_CUDA_VERSION
ARG UBUNTU_VERSION

ENV DEBIAN_FRONTEND=noninteractive
ENV QT_XCB_GL_INTEGRATION=xcb_egl
ENV PATH=/root/.local/bin:$PATH
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=packages/devel_packages.txt,target=devel_packages.txt \
    apt-get update && xargs -a devel_packages.txt apt-get install -y --no-install-recommends --no-install-suggests && \
    curl -LsSf https://astral.sh/uv/install.sh | sh && \
    rm -rf /var/lib/apt/* /var/cache/apt/*

# Build and install CMake
RUN wget https://github.com/Kitware/CMake/releases/download/v3.31.3/cmake-3.31.3-linux-x86_64.sh \
    -q -O /tmp/cmake-install.sh \
    && chmod u+x /tmp/cmake-install.sh \
    && mkdir /opt/cmake-3.31.3 \
    && /tmp/cmake-install.sh --skip-license --prefix=/opt/cmake-3.31.3 \
    && rm /tmp/cmake-install.sh \
    && ln -s /opt/cmake-3.31.3/bin/* /usr/local/bin

# Build and install GLOMAP.
RUN git clone https://github.com/colmap/glomap.git && \
    cd glomap && \
    git checkout "1.0.0" && \
    mkdir build && \
    cd build && \
    mkdir -p /build && \
    cmake .. -GNinja "-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES}" \
    -DCMAKE_INSTALL_PREFIX=/build/glomap && \
    ninja install -j`nproc` && \
    cd ~

# Build and install COLMAP.
RUN git clone https://github.com/colmap/colmap.git && \
    cd colmap && \
    git checkout "3.9.1" && \
    mkdir build && \
    cd build && \
    mkdir -p /build && \
    cmake .. -GNinja "-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES}" \
    -DCMAKE_INSTALL_PREFIX=/build/colmap && \
    ninja install -j`nproc` && \
    cd ~

# Upgrade pip and install dependencies.
# pip install torch==2.2.2 torchvision==0.17.2 --index-url https://download.pytorch.org/whl/cu118 && \
RUN uv pip install -n 'setuptools<70.0.0' 'numpy<2.0.0' --system && \
    uv pip install -n torch==2.1.2 torchvision==0.16.2 --index-url https://download.pytorch.org/whl/cu118 --system --native-tls && \
    git clone --branch master --recursive https://github.com/cvg/Hierarchical-Localization.git /opt/hloc && \
    cd /opt/hloc && git checkout v1.4 && uv pip install -n . --system && cd ~ && \
    TCNN_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" uv pip install -n "git+https://github.com/NVlabs/tiny-cuda-nn.git@b3473c81396fe927293bdfd5a6be32df8769927c#subdirectory=bindings/torch" --system --no-build-isolation && \
    uv pip install -n pycolmap==0.6.1 pyceres==2.1 omegaconf==2.3.0 --system

# Install gsplat and nerfstudio.
# NOTE: both are installed jointly in order to prevent docker cache with latest
# gsplat version (we do not expliticly specify the commit hash).
#
# We set MAX_JOBS to reduce resource usage for GH actions:
# - https://github.com/nerfstudio-project/gsplat/blob/db444b904976d6e01e79b736dd89a1070b0ee1d0/setup.py#L13-L23
COPY --from=source /tmp/nerfstudio/ /tmp/nerfstudio
RUN export TORCH_CUDA_ARCH_LIST="$(echo "$CUDA_ARCHITECTURES" | tr ';' '\n' | awk '$0 > 70 {print substr($0,1,1)"."substr($0,2)}' | tr '\n' ' ' | sed 's/ $//')" && \
    export MAX_JOBS=`nproc` && \
    GSPLAT_VERSION="$(sed -n 's/.*gsplat==\s*\([^," '"'"']*\).*/\1/p' /tmp/nerfstudio/pyproject.toml)" && \
    uv pip install -n git+https://github.com/nerfstudio-project/gsplat.git@v${GSPLAT_VERSION} --system --no-build-isolation && \
    uv pip install -n /tmp/nerfstudio 'numpy<2.0.0' --system && \
    rm -rf /tmp/nerfstudio

# Fix permissions
RUN chmod -R go=u /usr/local/lib/python3.10 && \
    chmod -R go=u /build

#
# Docker runtime stage.
#
FROM ghcr.io/kmu-fmcl/cuda:${NVIDIA_CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} as runtime
ARG CUDA_ARCHITECTURES
ARG NVIDIA_CUDA_VERSION
ARG UBUNTU_VERSION

LABEL org.opencontainers.image.source = "https://github.com/nerfstudio-project/nerfstudio"
LABEL org.opencontainers.image.licenses = "Apache License 2.0"
LABEL org.opencontainers.image.base.name="ghcr.io/kmu-fmcl/cuda:${NVIDIA_CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION}"
LABEL org.opencontainers.image.documentation = "https://docs.nerf.studio/"

# Minimal dependencies to run COLMAP binary compiled in the builder stage.
# Note: this reduces the size of the final image considerably, since all the
# build dependencies are not needed.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=packages/runtime_packages.txt,target=runtime_packages.txt \
    apt-get update && xargs -a runtime_packages.txt apt-get install -y --no-install-recommends --no-install-suggests

# Copy packages from builder stage.
# COPY --from=builder /usr/local/cuda/ /usr/local/cuda/
COPY --from=builder /build/colmap/ /usr/local/
COPY --from=builder /build/glomap/ /usr/local/
COPY --from=builder /usr/local/lib/python3.10/dist-packages/ /usr/local/lib/python3.10/dist-packages/
COPY --from=builder /usr/local/bin/ns* /usr/local/bin/

# Install nerfstudio cli auto completion
RUN /bin/bash -c 'ns-install-cli --mode install'

# Bash as default entrypoint.
CMD /bin/bash -l
