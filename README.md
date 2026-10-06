# Ubuntu 26.04 Docker images

Two images, rebuilt automatically by GitHub Actions and published to GitHub Container Registry (GHCR):

| Image | Purpose |
|---|---|
| `ghcr.io/<owner>/<repo>-base` | Slim Ubuntu 26.04 runtime (non-root `ubuntu` user) |
| `ghcr.io/<owner>/<repo>-builder` | Base + compilers, CMake, Ninja, git, Python |

Both are multi-arch (amd64 + arm64).

## Setup

1. Create a GitHub repo and push these files to `main`.
2. In **Settings > Actions > General > Workflow permissions**, choose *Read and write permissions*.
3. Push. See *Auto-update* below for when builds run.
4. Images appear under your profile or org's **Packages**. For public pulls, set package visibility to Public.

Tags: `26.04`, `latest` (main only), `sha-<commit>`, and semver on `v*` tags.

## Building apps into the images

### Option A: Multi-stage build (recommended)
Compile in `builder`, copy the result into `base`. The final image stays small and has no compilers.
See `examples/hello-c/Dockerfile`. Locally:

```bash
cd examples/hello-c
docker build -t hello \
  --build-arg BUILDER_IMAGE=ghcr.io/<owner>/<repo>-builder:latest \
  --build-arg BASE_IMAGE=ghcr.io/<owner>/<repo>-base:latest .
docker run --rm hello
```

### Option B: Add packages to the base
For apps installed from apt:

```dockerfile
FROM ghcr.io/<owner>/<repo>-base:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends nginx \
 && rm -rf /var/lib/apt/lists/*
USER ubuntu
```

### Option C: Interactive dev container
```bash
docker run --rm -it -v "$PWD":/src ghcr.io/<owner>/<repo>-builder:latest bash
```

### Language patterns (all use the multi-stage shape)
- **C/C++:** `cmake -S . -B build -G Ninja && cmake --build build`, then copy the binary.
- **Python:** in the builder, `python3 -m venv /opt/venv && /opt/venv/bin/pip install -r requirements.txt`; copy `/opt/venv` to base and install `python3` there.
- **Go / Rust / Node:** add the toolchain to a stage (apt `golang-go`, `cargo`, `nodejs npm`, or rustup), build, and copy the artifact into `base`.

### Automating your own app's build
In your app repo, add a job using the same `docker/build-push-action` step with `build-args` pointing at your builder/base tags (see the `example-app` job in `.github/workflows/build.yml`).

## Tips
- Pin by digest (`@sha256:...`) in production; Dependabot keeps the Dockerfile and actions current.
- Run `apt-get upgrade` in base (already done) so the weekly rebuild ships patched packages.
- Replace `OWNER/REPO` defaults in `examples/hello-c/Dockerfile` with yours.

---

## Auto-update

The workflow runs every 6 hours. A light `check` job resolves the newest version of everything; the heavy jobs run only if the combined fingerprint has no matching `fp-<hash>` tag on the published media image.

| Dependency | How "latest" is found |
|---|---|
| Ubuntu | `ubuntu:latest` (newest LTS) or `ubuntu:rolling` (newest release incl. interim), plus the image digest, so Ubuntu's own security rebuilds trigger a rebuild |
| Tdarr | newest version in Tdarr's `versions.json` |
| HandBrake | GitHub `releases/latest` |
| ffmpeg | date BtbN last republished the asset |
| apt packages | `apt-get upgrade` on every build, plus a weekly forced rebuild |
| Your own files | hash of `Dockerfile`, `docker/`, `patches/`, so a push also rebuilds |

Repo variables (Settings > Secrets and variables > Actions > Variables), all optional: `UBUNTU_TRACK` (`latest`|`rolling`), `TDARR_VERSION`, `HANDBRAKE_VERSION`, `FFMPEG_ASSET`. Use the pin variables to hold a version back. Run the workflow manually with **force** to rebuild now.

If an unattended update breaks the build, the `notify` job opens a single GitHub issue.

Notes: GitHub disables scheduled workflows after 60 days without repo activity (re-enable in the Actions tab), and schedules run only on the default branch. Pull requests build `base`/`builder` only (no push, no media/HandBrake).

## HandBrake is compiled in CI, not in the final image

`docker/handbrake.Dockerfile` compiles HandBrake with `--enable-qsv --enable-vce --enable-nvenc --enable-nvdec --enable-libdovi --enable-x265 --disable-gtk` and exports only `/opt/handbrake` as a scratch image (`<repo>-handbrake:<ver>-u<ubuntu>-<confighash>`). It rebuilds only when that tag doesn't exist, i.e. on a new HandBrake release, a new Ubuntu release, or a change to the Dockerfile/patches. The media image copies out the finished binary, so no compilers or sources ship. Put `git diff`-style `.patch` files in `patches/handbrake/` to customise the source.

## The `media` image

`ghcr.io/<owner>/<repo>-media`: Ubuntu + ffmpeg (static BtbN build) + HandBrakeCLI + Tdarr Node + mkvtoolnix/mediainfo + GPU userspace. Tags: `latest`, `ubuntu-<ver>`, `tdarr-<ver>`, `hb-<ver>`, `fp-<hash>`.

### GPU support

| GPU | In the image | You provide on the host |
|---|---|---|
| NVIDIA (NVENC/NVDEC) | `NVIDIA_DRIVER_CAPABILITIES=compute,video,utility`; ffmpeg and HandBrake built with NVENC/NVDEC | NVIDIA driver + [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/) |
| Intel (QSV/VAAPI) | iHD driver, oneVPL runtime, OpenCL | `/dev/dri` passed through |
| AMD (VAAPI/Vulkan) | Mesa VAAPI + Vulkan | `/dev/dri` passed through |
| AMD AMF (HandBrake `--enable-vce`) | built in | AMF needs AMD's proprietary runtime library (`libamfrt64`), which is not in Ubuntu's repos and is not baked in; prefer VAAPI on AMD |

Run (NVIDIA):
```bash
docker run -d --gpus all --name tdarr-node \
  -e serverIP=192.168.1.10 -e serverPort=8266 -e nodeName=gpu-node \
  -v tdarr-node-data:/data/tdarr -v /path/to/media:/media -v /path/to/cache:/temp \
  ghcr.io/<owner>/<repo>-media:latest
```
Intel/AMD: replace `--gpus all` with `--device /dev/dri --group-add $(getent group render | cut -d: -f3)` (add `--group-add video` if needed).

Verify inside the container:
```bash
docker exec -it tdarr-node vainfo                       # Intel/AMD
docker exec -it tdarr-node nvidia-smi                   # NVIDIA
docker exec -it tdarr-node ffmpeg -hide_banner -hwaccels
docker exec -it tdarr-node HandBrakeCLI --help | grep -E 'nvenc|qsv|vce'   # lists only encoders usable on this host
```
CI has no GPU, so the smoke test checks that ffmpeg contains the NVENC/QSV/VAAPI encoders and HandBrake's libraries resolve, not that hardware encoding works.

### Local build
```bash
docker build -f docker/handbrake.Dockerfile --target artifact --build-arg HANDBRAKE_VERSION=1.11.2 -t hb-artifact .
docker build --target media -t media \
  --build-arg HANDBRAKE_IMAGE=hb-artifact --build-arg HANDBRAKE_VERSION=1.11.2 --build-arg TDARR_VERSION=<ver> .
```

### Adding another app
Add a build stage that installs into its own prefix, `COPY --from=` it in the `media` stage, and add any runtime apt packages to the `apt-get install` line. For a heavy compile, copy the HandBrake pattern: a separate Dockerfile, a scratch artifact image, and a job that skips when the tag exists.

### Licensing
Tdarr is proprietary freeware: check its terms before making this image public. Don't publish a build that uses `--enable-fdk-aac`. The NVIDIA, Intel non-free media driver and AMF components have their own licences.

---

## Reading the workflow logs

**On the run page (Summary tab)** every job writes a short report:
- `check`: a table of Ubuntu / Tdarr / HandBrake / ffmpeg showing *published image vs latest* with `updated` flags, and the decision (**build** or **skip**) with the reason.
- `base-builder`, `handbrake`, `media`: what was built, tags, digest, image size, and for HandBrake how long the compile took or that it was skipped because the artifact already exists.
- `media` also shows a smoke-test table (ffmpeg and HandBrake run, GPU encoders present, libraries resolve, Tdarr present). Every check runs even if one fails, so you see all problems at once.
- `report`: one table of all job results plus the versions in play.

**In the step logs**
- Each script line is timestamped `[HH:MM:SS]`; sections are collapsed into groups. Turn on *Show timestamps* in the log viewer for per-line times.
- HandBrake compiles in five labelled phases (`=== 3/5 configure ===`, `=== 4/5 compile ===`, ...). Each build line also carries BuildKit's elapsed seconds.
- If a phase fails, a failure report is printed **last**: the exit code, how long it ran, the final 120 log lines, and the lines that look like errors.
- Failed jobs run a *Diagnostics on failure* step: disk space (the usual HandBrake killer), Docker cache usage, ffmpeg's build configuration, installed GPU packages, and HandBrake's linked libraries.
- Failures are also raised as red annotations at the top of the run, and on a failed scheduled run a single GitHub issue lists the failed job, the failed step and a link.

**Deeper debugging**
- Open the *Docker Build Summary* on the run page for the exact failing instruction.
- Download the `.dockerbuild` artifact (kept 14 days) and open it in Docker Desktop for the full build record.
- Re-run the job with *Enable debug logging* for extra runner detail.
- Jobs have timeouts (HandBrake 180 min, others shorter), so a hang ends with a clear "timed out" instead of running for hours.
