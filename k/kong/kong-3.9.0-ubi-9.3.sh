#!/bin/bash -e
# -----------------------------------------------------------------------------
#
# Package           : kong
# Version           : 3.90
# Source repo   : https://github.com/kong/kong
# Tested on         : UBI 9.3
# Language      : Rust
# Travis-Check  : true
# Script License: Apache License, Version 2 or later
# Maintainer    : Kavia Rane <Kavita.Rane2@ibm.com>
#
# Disclaimer: This script has been tested in root mode on given
# ==========  platform using the mentioned version of the package.
#             It may not work as expected with newer versions of the
#             package and/or distribution. In such case, please
#             contact "Maintainer" of this script.
#
# --------------------------------------------------------------------------------

if [ -z "${GITHUB_TOKEN}" ]; then
  echo "missing github_token. Please set Environment Variable <GITHUB_TOKEN>"
  exit 1
fi

PACKAGE_NAME=kong
PACKAGE_VERSION=${1:-3.9.0}
PACKAGE_URL=https://github.com/kong/kong/
PYTHON_VERSION=3.11.0
GO_VERSION=1.23.0

dnf update -y
dnf install -y --allowerasing \
    automake \
    gcc \
    gcc-c++ \
    git \
    libyaml-devel \
    make \
    patch \
    perl \
    perl-IPC-Cmd \
    zip unzip \
    valgrind \
    valgrind-devel \
    zlib-devel \
    wget \
    cmake \
    java-21-openjdk-devel \
    tzdata-java \
    curl \
    file

wdir=`pwd`
#Set environment variables
export JAVA_HOME=$(compgen -G '/usr/lib/jvm/java-21-openjdk-*')
export JRE_HOME=${JAVA_HOME}/jre
export PATH=${JAVA_HOME}/bin:$PATH

#Install Python from source
if [ -z "$(ls -A $wdir/Python-${PYTHON_VERSION})" ]; then
       wget https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz
       tar xzf Python-${PYTHON_VERSION}.tgz
       rm -rf Python-${PYTHON_VERSION}.tgz
       cd Python-${PYTHON_VERSION}
       ./configure --enable-shared --with-system-ffi --with-computed-gotos --enable-loadable-sqlite-extensions
       make -j ${nproc}
else
       cd Python-${PYTHON_VERSION}
fi

make altinstall
ln -sf $(which python3.11) /usr/bin/python3
ln -sf $(which pip3.11) /usr/bin/pip3
ln -sf /usr/share/pyshared/lsb_release.py /usr/local/lib/python3.11/site-packages/lsb_release.py
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$wdir/Python-3.11.0/lib
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib
python3 -V && pip3 -V

#Download source code
cd $wdir
rm -rf $wdir/${PACKAGE_NAME}
git clone ${PACKAGE_URL}
cd ${PACKAGE_NAME} && git checkout ${PACKAGE_VERSION}
BAZEL_VERSION=$(cat .bazelversion)

# Build and setup bazel
cd $wdir
if [ -z "$(ls -A $wdir/bazel)" ]; then
        mkdir bazel
        cd bazel
        wget https://github.com/bazelbuild/bazel/releases/download/${BAZEL_VERSION}/bazel-${BAZEL_VERSION}-dist.zip
        unzip bazel-${BAZEL_VERSION}-dist.zip
        rm -rf bazel-${BAZEL_VERSION}-dist.zip
        #./compile.sh
		
		export BAZEL_JAVAC_OPTS="-J-Xmx20g"
        env EXTRA_BAZEL_ARGS="--tool_java_runtime_version=local_jdk" bash ./compile.sh -j32

fi
export PATH=$PATH:$wdir/bazel/output

#Install rust and cross
curl https://sh.rustup.rs -sSf | sh -s -- -y && source ~/.cargo/env
cargo install cross --version 0.2.1

#Install Golang
cd $wdir
wget https://golang.org/dl/go${GO_VERSION}.linux-ppc64le.tar.gz
tar -C /usr/local -xvzf go${GO_VERSION}.linux-ppc64le.tar.gz
rm -rf go${GO_VERSION}.linux-ppc64le.tar.gz

export PATH=$PATH:/usr/local/go/bin
go version
GOBIN=/usr/local/go/bin go install github.com/cli/cli/v2/cmd/gh@v2.50.0	
GHCLI_BIN=/usr/local/go/bin/gh

#Patch and build  Kong
cd $wdir/${PACKAGE_NAME}
git apply --ignore-space-change --ignore-whitespace $wdir/kong-${PACKAGE_VERSION}.patch
make build-release > /dev/null 2>&1 || true

#Patch rules_rust
pushd $(find $HOME/.cache/bazel -name rules_rust) 
git apply --ignore-space-change --ignore-whitespace  $wdir/kong-${PACKAGE_VERSION}-rules_rust-0.42.1.patch


#Build cargo-bazel native binary
cd crate_universe
cargo update -p time
cross build --release --locked --bin cargo-bazel --target=powerpc64le-unknown-linux-gnu 
export CARGO_BAZEL_GENERATOR_URL=file://$(pwd)/target/powerpc64le-unknown-linux-gnu/release/cargo-bazel
export CARGO_BAZEL_REPIN=true
echo "cargo-bazel build successful!"
popd



#Build kong .deb package
echo "Building Kong debian package..."
cd $wdir/${PACKAGE_NAME}
make package/deb  > /dev/null 2>&1 || true

cp -f $GHCLI_BIN $(find $HOME/.cache/bazel -type d -name gh_linux_ppc64le)/bin

make package/deb 

make package/rpm
cp $(find / -name kong.el8.ppc64le.rpm) $wdir
export KONG_RPM=$wdir/kong.el8.ppc64le.rpm

#Conclude
set +ex
echo "Build successful!"
echo "Kong RPM package available at [$KONG_RPM]"
