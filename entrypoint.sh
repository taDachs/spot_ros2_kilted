#!/usr/bin/bash
source /opt/ros/$ROS_DISTRO/setup.bash

if [[ -f /ros_ws/install/setup.bash ]]; then
  source /ros_ws/install/setup.bash
fi

# Execute the command passed into this entrypoint.
exec "$@"
