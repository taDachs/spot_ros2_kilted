# spot_ros2 (ROS 2 Kilted) — Docker build

This repo builds the `spot_ros2` driver (and dependencies) for **ROS 2 Kilted** inside a multi-stage Docker build.

## What you get

A Docker image (`spot_ros2:kilted`) that contains:

- ROS 2 **Kilted** base
- Spot C++ SDK built and installed to `/usr/local`
- Required vcpkg deps (grpc, eigen3, cli11)
- `spot_ros2` workspace built

## Important note (vcpkg)

**Any CMake-based build that depends on the Spot SDK or its dependencies must be configured with:**

```bash
-DCMAKE_TOOLCHAIN_FILE=/vcpkg/scripts/buildsystems/vcpkg.cmake
```

This is required so CMake can find the libraries provided via vcpkg.

## Build

```bash
docker buildx build \
  -t spot_ros2:kilted \
  --build-arg ROS_DISTRO_VERSION=kilted \
  --target spot_ros2 \
  --progress plain \
  .
```
