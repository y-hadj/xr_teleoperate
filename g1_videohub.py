"""Stop/start Unitree's head-camera streamer (video_hub_pc4) so teleimager can open the RealSense.

Unitree's service manager restarts video_hub_pc4 if it is killed, so it is switched off through
the robot_state service API instead. The setting does not survive a robot reboot.

Usage (laptop, conda env tv, Ethernet connected):
    python g1_videohub.py off <eth-iface>    # before starting teleimager-server
    python g1_videohub.py on  <eth-iface>    # give the camera back to Unitree's app
    python g1_videohub.py     <eth-iface>    # status only
"""
import sys

from unitree_sdk2py.core.channel import ChannelFactoryInitialize
from unitree_sdk2py.go2.robot_state.robot_state_client import RobotStateClient

args = sys.argv[1:]
action = args.pop(0) if args and args[0] in ("on", "off") else "status"
iface = args[0] if args else None

ChannelFactoryInitialize(0, iface)
client = RobotStateClient()
client.SetTimeout(3.0)
client.Init()

if action in ("on", "off"):
    code = client.ServiceSwitch("video_hub_pc4", action == "on")
    print(f"video_hub_pc4 -> {action}: return code {code}")

code, services = client.ServiceList()
if code != 0:
    sys.exit(f"ServiceList failed (code {code}). Is the robot reachable on {iface or 'the default interface'}?")
for s in services:
    if s.name.startswith("video_hub"):
        print(f"{s.name}: {'running' if s.status == 0 else 'stopped'}")
