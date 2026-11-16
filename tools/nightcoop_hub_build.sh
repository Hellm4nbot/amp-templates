#!/bin/sh
# NightCoop hub - AMP 3 build stage.
# Builds the hub from source, as its own Dockerfile does, but straight into the instance
# directory. No published binary exists upstream, so the template compiles it.
#
# Usage: sh nightcoop_hub_build.sh <instance base directory>
set -e

BASE="${1:-.}"
HUBSHA="6b694a6c86fd7c2b93743497ab3bd924553f25b8"
ENETSHA="5a9c537fd464b3c6d3c55e1d3bd47588faf71b42"

cd "$BASE"

echo "NightCoop hub build - base directory: $BASE"

if ! command -v g++ >/dev/null 2>&1; then
    echo "ERROR: no C++ compiler in this instance."
    echo "ERROR: AMP 3 installs no package at runtime, so the toolchain has to come from the image."
    echo "ERROR: set Meta.SpecificDockerImage to cubecoders/amp3base:postgresql (or :redis), which ship g++."
    exit 1
fi
g++ --version | head -n1

rm -rf src
mkdir -p src obj
rm -f nightcoop_hub

echo "Hub sources: $HUBSHA"
curl -sSL -o /tmp/nightcoop-hub.tar.gz "https://codeload.github.com/Twenfys/nightcoop-hub/tar.gz/$HUBSHA"
tar -xzf /tmp/nightcoop-hub.tar.gz -C src
rm -f /tmp/nightcoop-hub.tar.gz
mv "src/nightcoop-hub-$HUBSHA" src/hub

echo "ENet sources: $ENETSHA"
curl -sSL -o /tmp/enet.tar.gz "https://codeload.github.com/lsalzman/enet/tar.gz/$ENETSHA"
tar -xzf /tmp/enet.tar.gz -C src
rm -f /tmp/enet.tar.gz
mv "src/enet-$ENETSHA" src/enet

echo "Compiling ENet..."
for f in callbacks compress host list packet peer protocol unix; do
    gcc -c -O2 -I src/enet/include \
        -DHAS_FCNTL=1 -DHAS_POLL=1 -DHAS_SOCKLEN_T=1 -DHAS_MSGHDR_FLAGS=1 -DHAS_GETADDRINFO=1 \
        -DHAS_GETNAMEINFO=1 -DHAS_INET_PTON=1 -DHAS_INET_NTOP=1 -DHAS_GETHOSTBYNAME_R=1 -DHAS_GETHOSTBYADDR_R=1 \
        "src/enet/$f.c" -o "obj/enet_$f.o"
done
gcc -c -O2 src/hub/vendor/monocypher/monocypher.c -o obj/monocypher.o

echo "Compiling the hub..."
cd src/hub
for f in src/Log.cpp src/NetCrypto.cpp src/HubServer.cpp tools/hub/main.cpp; do
    g++ -c -std=c++20 -O2 -w -I ../../src/enet/include "$f" -o "../../obj/$(basename "$f" .cpp).o"
done
cd "$BASE"
g++ -o nightcoop_hub obj/*.o -pthread -static-libstdc++ -static-libgcc
chmod 755 nightcoop_hub

echo "Compiled binary self-test..."
./nightcoop_hub --gen-sign-key /tmp/amp-hub-smoke.key >/dev/null
./nightcoop_hub --hub-public /tmp/amp-hub-smoke.key | grep '^nightcoop-hub-public' | cut -c1-72
rm -f /tmp/amp-hub-smoke.key

# les sources et les objets ne servent plus : le binaire est autonome (libstdc++ statique)
rm -rf src obj
mkdir -p data
echo "Done: $(wc -c < nightcoop_hub) bytes, sha256 $(sha256sum nightcoop_hub | cut -d' ' -f1)"
