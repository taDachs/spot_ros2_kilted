ARG ROS_DISTRO_VERSION="kilted"

# base image
FROM ros:${ROS_DISTRO_VERSION}-ros-base AS base
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN printf 'APT::Install-Recommends "false";\nAPT::Install-Suggests "false";' > /etc/apt/apt.conf.d/01-no-recursive
RUN rm -f /etc/apt/apt.conf.d/docker-clean; echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

ARG ROS_DISTRO_VERSION

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# install basic tool that are needed in any stage
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ninja-build \
    apt-utils \
    python3-pip \
    curl \
    wget \
    git \
    openssh-client \
    g++ \
    pkg-config \
    curl \
    tar \
    zip \
    unzip \
    ros-${ROS_DISTRO_VERSION}-rmw-cyclonedds-cpp \
    ros-${ROS_DISTRO_VERSION}-rmw-fastrtps-cpp \
    ros-${ROS_DISTRO_VERSION}-rmw-zenoh-cpp \
  && pip3 install --no-cache-dir vcstool \
  && rm -rf /var/lib/apt/lists/*

# make sure git remotes are known hosts
RUN mkdir -p /root/.ssh && \
  ssh-keyscan github.com >> /root/.ssh/known_hosts
####################################################################################################

FROM base AS vcpkg-builder

ARG TARGETARCH
ARG ROS_DISTRO_VERSION

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked apt-get update \
  && apt-get update \
  && apt-get -y install \
  zlib1g-dev \
  libssl-dev \
  && rm -rf /var/lib/apt/lists/*

RUN <<'EOF'
  set -eux
  git clone https://github.com/microsoft/vcpkg.git
  cd vcpkg
  git checkout 3b213864579b6fa686e38715508f7cd41a50900f
  # disable debug builds
  find triplets/* -type f -exec sh -c "echo \"\nset(VCPKG_BUILD_TYPE release)\n\" >> {}" \;
  export VCPKG_BUILD_TYPE=release
  if [ "${TARGETARCH}" = "amd64" ]; then
    ./bootstrap-vcpkg.sh
    ./vcpkg install grpc:x64-linux
    ./vcpkg install eigen3:x64-linux
    ./vcpkg install cli11:x64-linux
  else
    export VCPKG_FORCE_SYSTEM_BINARIES=arm
    # on older ubuntu version the cmake version is too old for vcpkg
    # see https://github.com/microsoft/vcpkg/issues/44621
    if [ "${ROS_DISTRO_VERSION}" = "humble" ]; then
      # yes this is kinda messed up
      cd /tmp
      wget https://github.com/Kitware/CMake/releases/download/v3.25.3/cmake-3.25.3-linux-aarch64.tar.gz
      tar zxvf cmake-3.25.3-linux-aarch64.tar.gz
      cd cmake-3.25.3-linux-aarch64
      cp -r bin/* /usr/local/bin
      cp -r share/* /usr/local/share
      cd ..
      rm -rf cmake-3.25.3-linux-aarch64
      cd /vcpkg
    fi
    ./bootstrap-vcpkg.sh
    ./vcpkg install grpc:arm64-linux
    ./vcpkg install eigen3:arm64-linux
    ./vcpkg install cli11:arm64-linux
  fi

  # remove all the stuff that is no longer needed
  rm -rf buildtrees packages downloads archives .git
EOF

####################################################################################################

FROM base AS spot-sdk-builder

ARG TARGETARCH
ARG ROS_DISTRO_VERSION

# copy vcpkg for later
COPY --from=vcpkg-builder /vcpkg /vcpkg

# build spot sdk
# TODO: (MSc) the current spot sdk is not buildable on 24.04, wait until my PR is merged
RUN <<'EOF'
  set -eux
  git clone https://github.com/tadachs/spot-cpp-sdk.git
  cd spot-cpp-sdk/cpp
  mkdir build
  cd build
  cmake ../ -DCMAKE_TOOLCHAIN_FILE=/vcpkg/scripts/buildsystems/vcpkg.cmake -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=TRUE
  make -j8
  make -j8 install package
  cd ..
  rm -rf build
EOF

####################################################################################################

FROM base AS ros-builder

ARG TARGETARCH
ARG ROS_DISTRO_VERSION

# copy vcpkg for later
COPY --from=vcpkg-builder /vcpkg /vcpkg

# copy spot sdk
COPY --from=spot-sdk-builder /usr/local /usr/local

RUN mkdir -p /ros_ws/src

# TODO: (MSc) proto2ros also needs a pr
# WARN: Its kinda messed up to just copy the install folder to the global workspace, the
# reason is that with --install-base a setup.bash is generated at the same location, which breaks
# ros
RUN --mount=type=ssh \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked <<'EOF'
  set -e
  cd /ros_ws/src

  git clone https://github.com/bdaiinstitute/bosdyn_msgs.git
  git clone https://github.com/tadachs/proto2ros.git
  git clone https://github.com/tadachs/spot_ros2.git --branch kilted
  git clone https://github.com/bdaiinstitute/synchros2.git  # needs current version of synchros2 for kilted support
  cd spot_ros2
  git submodule init
  git submodule update
  cd ..

  touch bosdyn_msgs/proto2ros/COLCON_IGNORE  # have to use my version and it is a submodule
  touch proto2ros/proto2ros_tests/COLCON_IGNORE  # just wastes a lot of time
  touch spot_ros2/ros_utilities/COLCON_IGNORE

  cd ..
  apt update
  PIP_CONSTRAINT=src/bosdyn_msgs/pip-constraint.txt rosdep install -i -y -r --from-path src  --skip-keys "$(cat src/bosdyn_msgs/rosdep-skip.txt)"
  # missing dep for rviz plug
  apt install --no-install-recommends -y qttools5-dev
  source /opt/ros/${ROS_DISTRO_VERSION}/setup.bash
  colcon build --cmake-args -DCMAKE_TOOLCHAIN_FILE=/vcpkg/scripts/buildsystems/vcpkg.cmake -DCMAKE_BUILD_TYPE=Release
  rm -rf build log
  rm -rf /var/lib/apt/lists/*
EOF

###################################################################################################

FROM base AS spot-sdk

# copy spot sdk
COPY --from=spot-sdk-builder /usr/local /usr/local
# copy vcpkg for later
COPY --from=vcpkg-builder /vcpkg /vcpkg

# install bosdyn pip packages
RUN pip3 install --ignore-installed --no-cache-dir --upgrade \
  bosdyn-client \
  bosdyn-mission \
  bosdyn-choreography-client \
  bosdyn-orbit

####################################################################################################

FROM spot-sdk AS spot_ros2

COPY --from=ros-builder /opt/ros/${ROS_DISTRO_VERSION}/ /opt/ros/${ROS_DISTRO_VERSION}/
COPY --from=ros-builder /ros_ws /ros_ws

RUN apt update && \
  cd /ros_ws && \
  PIP_CONSTRAINT=src/bosdyn_msgs/pip-constraint.txt rosdep install -i -y -r --from-path src --skip-keys "$(cat src/bosdyn_msgs/rosdep-skip.txt)" && \
  pip install multipledispatch aiortc numpy==1.26.4 pillow && \
  pip install \
    bosdyn-api==5.0.1 \
    bosdyn-choreography-client==5.0.1 \
    bosdyn-client==5.0.1 \
    bosdyn-core==5.0.1 \
    bosdyn-mission==5.0.1 \
    bosdyn-orbit==5.0.1 && \
  rm -rf /var/lib/apt/lists/*

CMD /bin/bash

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
RUN echo "source /entrypoint.sh" >> ~/.bashrc

