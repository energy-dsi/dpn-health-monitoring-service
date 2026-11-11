# ---------------------------------------------------------------------------
# Alpine-based image. Alpine uses musl libc, NOT glibc, so glibc CVEs (JFrog
# X-Ray flagged a long list against python:3.11-slim's Debian base — libc6,
# ncurses, util-linux, perl-base, ... many with no fixed Debian package at
# all yet) do not apply here at all. Same base family dpn-file-scan-service's
# Dockerfile uses, for the same reason.
#
# Kept single-stage and on Python 3.11 (not the 3.14 + multi-stage build
# dpn-file-scan-service uses) deliberately: this app has no build toolchain
# to isolate from the runtime image (every dependency below resolves to a
# prebuilt musllinux wheel), so a second stage would add complexity without
# reducing image size, and bumping the Python version is a separate change
# with its own compatibility risk this fix doesn't need to take on.
# ---------------------------------------------------------------------------
FROM python:3.11-alpine

WORKDIR /app

COPY requirements.txt .

# Single layer:
#   1. Pull any OS package fixes Alpine has published.
#   2. Install the app's dependencies (--only-binary=:all: -- every package
#      in requirements.txt resolves to a prebuilt musllinux wheel; a source
#      build here would mean a missing wheel went unnoticed).
#   3. Remove pip/setuptools/wheel from the shipped image -- build-time
#      tools this app never calls at runtime, and JFrog flags known issues
#      in pip itself when left in the final image.
#      Paths below are /usr/local, not /usr/lib: this base image (like every
#      official python:* image) builds Python from source into /usr/local,
#      so that's where pip installs both this app's deps and itself -- a
#      previous /usr/lib/python3.11/... version of this step matched nothing
#      and silently left pip/setuptools/wheel in the shipped image.
#      jaraco.context ships as setuptools' own install_requires (its
#      pkg_resources vendor/build-backend dependency) but lands as its own
#      top-level dist-info, not under a setuptools*/pip*/wheel* prefix -- so
#      it survived the glob below and kept showing up as a standalone High
#      CVE (jaraco.context) in JFrog X-Ray even after pip/setuptools/wheel
#      themselves were removed. Uninstalled explicitly for the same reason.
#      `! python3 -c "import pip"` re-verifies removal so a future path
#      mismatch fails the build instead of shipping unnoticed again.
RUN apk update && \
    apk upgrade --no-cache && \
    pip install --no-cache-dir --only-binary=:all: -r requirements.txt && \
    pip uninstall -y pip setuptools wheel jaraco.context && \
    rm -rf /usr/local/lib/python3.11/site-packages/pip* \
           /usr/local/lib/python3.11/site-packages/setuptools* \
           /usr/local/lib/python3.11/site-packages/wheel* \
           /usr/local/lib/python3.11/site-packages/jaraco* \
           /usr/local/bin/pip* && \
    ! python3 -c "import pip" 2>/dev/null

COPY main.py .
COPY portal ./portal
COPY templates ./templates
COPY static ./static

# Alpine's BusyBox adduser, not useradd. -u pins the UID to match
# charts/dpn-portal/templates/deployment.yaml's runAsUser: 10001 exactly;
# -D skips the password prompt, -H skips creating a home directory this app
# never needs.
RUN adduser -D -H -u 10001 portal
USER 10001

EXPOSE 8000

# --loop asyncio: uvicorn is installed plain, without the [standard] extra
# (see requirements.txt), so no uvloop is present -- pin the loop explicitly
# rather than let uvicorn silently fall back and warn.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--loop", "asyncio"]
