FROM debian:buster AS builder

ENV DEBIAN_FRONTEND noninteractive
ENV TERM dumb
ENV PAGER cat

ARG BOOST_VERSION=1.58.0
ARG CMAKE_VERSION=3.25.1

RUN mkdir -pv /build/ /artifacts/ /src/

RUN sed -i s/deb.debian.org/mirrors.aliyun.com/g /etc/apt/sources.list
RUN apt-get update && apt-get upgrade
RUN apt-get -qq -o Dpkg::Use-Pty=0 update \
    && apt-get -qq -o Dpkg::Use-Pty=0 install --no-install-recommends -y \
    autoconf \
    binutils \
    build-essential \
    ca-certificates \
    ccache \
    clang \
    cmake \
    curl \
    e2fslibs-dev \
    file \
    gettext-base \
    g++ \
    gcc \
    git \
    gnupg \
    gzip \
    jq \
    libblkid-dev \
    # libboost-all-dev \
    # libboost-dev \
    # libboost-filesystem-dev \
    # libboost-iostreams-dev \
    # libboost-locale-dev \
    # libboost-program-options-dev \
    # libboost-regex-dev \
    # libboost-system-dev \
    # libboost-thread-dev \
    libbz2-dev \
    libcurl4-openssl-dev \
    libmagic-dev \
    libmariadb-dev \
    libmariadb-dev-compat \
    default-libmysqlclient-dev \
    libncurses-dev \
    libpq-dev \
    libreadline-dev \
    libssl-dev \
    libsqlite3-dev \
    lsof \
    make \
    default-mysql-client \
    nano \
    net-tools \
    netcat \
    openssh-client \
    parallel \
    patch \
    pkg-config \
    postgresql-client \
    python-is-python3 \
    retry \
    shellcheck \
    software-properties-common \
    ssh \
    sudo \
    tar \
    tzdata \
    unzip \
    vim \
    wget \
    xml2 \
    zip \
    zlib1g-dev \
    && add-apt-repository ppa:git-core/ppa && apt-get install -y git \
    && curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | bash && apt-get install -y git-lfs \
    && git version && git lfs version \
    && python --version \
    && rm -rf /var/lib/apt/lists/*

# Install CMake
# RUN cd /tmp && \
#     wget https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}.tar.gz && \
#     tar xzf cmake-${CMAKE_VERSION}.tar.gz && \
#     cd cmake-${CMAKE_VERSION} && \
#     ./bootstrap && \
#     make -j $(nproc) && \
#     make install && \
#     rm -rf /tmp/*

# Install Boost
# https://www.boost.org/doc/libs/1_80_0/more/getting_started/unix-variants.html
RUN cd /tmp && \
    BOOST_VERSION_MOD=$(echo $BOOST_VERSION | tr . _) && \
    wget https://boostorg.jfrog.io/artifactory/main/release/${BOOST_VERSION}/source/boost_${BOOST_VERSION_MOD}.tar.bz2 && \
    tar --bzip2 -xf boost_${BOOST_VERSION_MOD}.tar.bz2 && \
    cd boost_${BOOST_VERSION_MOD} && \
    ./bootstrap.sh --prefix=/usr/local && \
    ./b2 install && \
    rm -rf /tmp/*

RUN update-alternatives --install /usr/bin/cc cc /usr/bin/clang 100 && \
    update-alternatives --install /usr/bin/c++ c++ /usr/bin/clang 100

COPY cmake /src/cmake
COPY contrib /src/contrib
COPY dep /src/dep
COPY sql /src/sql
COPY src /src/src
COPY sql /src/sql
COPY .git /src/.git
COPY CMakeLists.txt PreLoad.cmake revision_data.h.in.cmake COPYING /src/

RUN mkdir /artifacts/src/

WORKDIR /build

ARG INSTALL_PREFIX=/opt/trinitycore
ARG CONF_DIR=/etc
RUN cmake ../src -DWITH_WARNINGS=0 -DWITH_COREDEBUG=0 -DUSE_COREPCH=1 -DUSE_SCRIPTPCH=1 -DTOOLS=1 -DSCRIPTS=static -DSERVERS=1 -DNOJEM=0 -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="-Werror" -DCMAKE_CXX_FLAGS="-Werror" -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" -DBUILD_TESTING=0 -DCONF_DIR="${CONF_DIR}" -Wno-dev
RUN make -j $(nproc) \
    && make install

WORKDIR /artifacts

# Save upstream source Git SHA information that we built form.
ARG TDB_FULL_URL
RUN git -C /src rev-parse HEAD > .git-rev \
    && git -C /src rev-parse --short HEAD > .git-rev-short \
    && echo "$TDB_FULL_URL" > .tdb-full-url

# Copy binaries and example .dist.conf configuration files.
RUN tar -cf - \
    "${INSTALL_PREFIX}" \
    /bin/bash \
    /etc/ca-certificates* \
    /etc/*server.conf.dist \
    /etc/ssl/certs \
    /src/AUTHORS \
    /src/COPYING \
    /usr/bin/7zr \
    /usr/bin/curl \
    /usr/bin/git \
    /usr/bin/jq \
    /usr/bin/mariadb \
    /usr/bin/mysql \
    /usr/bin/stdbuf \
    /usr/bin/xml2 \
    /usr/lib/git-core/git-remote-http* \
    /usr/lib/p7zip/7zr \
    /usr/libexec/coreutils/libstdbuf.so \
    /usr/share/ca-certificates \
    | tar -C /artifacts/ -xvf -

# Copy linked libraries and strip symbols from binaries.
RUN ldd opt/trinitycore/bin/* usr/bin/* usr/lib/git-core/* | grep ' => ' | tr -s '[:blank:]' '\n' | grep '^/' | sort -u | \
    xargs -I % sh -c 'mkdir -pv $(dirname .%); cp -v % .%'
RUN strip \
    "./${INSTALL_PREFIX}/bin/"*server \
    "./${INSTALL_PREFIX}/bin/"*extractor \
    "./${INSTALL_PREFIX}/bin/"*generator \
    "./${INSTALL_PREFIX}/bin/"*assembler

# Copy example .conf.dist configuration files into expected .conf locations.
RUN cp -v etc/bnetserver.conf.dist etc/bnetserver.conf \
    && cp -v etc/worldserver.conf.dist etc/worldserver.conf \
    && find etc/ -name '*server.conf' -exec sed -i"" -r \
    -e 's,^(.*DatabaseInfo[[:space:]]*=[[:space:]]*")[[:alnum:]\.-]*(;.*"),\1mysql\2,' \
    -e 's,^(LogsDir[[:space:]]*=[[:space:]]).*,\1"/logs",' \
    -e 's,^(SourceDirectory[[:space:]]*=[[:space:]]).*,\1"/src",' \
    -e 's,^(MySQLExecutable[[:space:]]*=[[:space:]]).*,\1"/usr/bin/mysql",' \
    '{}' \; \
    && sed -i"" -r \
    -e 's,^(DataDir[[:space:]]*=[[:space:]]).*,\1"/mapdata",' \
    -e 's,^(Console\.Enable[[:space:]]*=[[:space:]]).*,\10,' \
    etc/worldserver.conf \
    && mkdir -pv "./${INSTALL_PREFIX}/etc/" \
    && ln -s -T /etc/worldserver.conf      "./${INSTALL_PREFIX}/etc/worldserver.conf" \
    && ln -s -T /etc/worldserver.conf.dist "./${INSTALL_PREFIX}/etc/worldserver.conf.dist" \
    && ln -s -T /etc/bnetserver.conf       "./${INSTALL_PREFIX}/etc/authserver.conf" \
    && ln -s -T /etc/bnetserver.conf.dist  "./${INSTALL_PREFIX}/etc/authserver.conf.dist"


FROM busybox:1.35.0-glibc

ARG INSTALL_PREFIX=/opt/trinitycore
ENV LD_LIBRARY_PATH=/lib:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:${INSTALL_PREFIX}/lib \
    PATH=/bin:/usr/bin:${INSTALL_PREFIX}/bin

COPY --from=builder /artifacts /

ARG TRINITY_UID=1000
ARG TRINITY_GID=1000
RUN addgroup -g "${TRINITY_GID}" trinity \
    && adduser -G trinity -D -u "${TRINITY_UID}" -h "${INSTALL_PREFIX}" trinity
USER trinity
WORKDIR /

VOLUME ["/opt/trinitycore/logs", "/opt/trinitycore/data", "opt/trinitycore/sql"]

ARG TC_GIT_BRANCH=7.3.5
