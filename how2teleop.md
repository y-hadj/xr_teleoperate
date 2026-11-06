# G1 (29 DoF) + Meta Quest (or Pico) — Quickstart

Short version of [README_G1_REAL_ROBOT.md](https://github.com/unitreerobotics/xr_teleoperate) (details and troubleshooting there).

- Laptop `192.168.123.100` (Ethernet) · PC2 `192.168.123.164` · hotspot `G1-Hotspot` / `g1robot123`, PC2 `192.168.4.1`

- `<eth-iface>` = laptop's wired interface (e.g. `enxc84d443568a7`), `LAPTOP_IP` = laptop's `192.168.4.x` address

- On PC2, always `unset PYTHONPATH` before `conda activate`.


## Laptop Setup (needs internet)

Install conda if it is not the case yet :

```bash
# Miniconda (skip if conda is installed)
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O ~/miniconda.sh
bash ~/miniconda.sh -b -u -p ~/miniconda3 && rm ~/miniconda.sh
~/miniconda3/bin/conda init bash && source ~/.bashrc
conda config --set auto_activate false       # conda available, but no (base) in every new terminal
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
```

Create a new virtual environment, and install the dependencies inside :

```bash
conda create -n tv python=3.10 pinocchio=3.1.0 numpy=1.26.4 -c conda-forge -y && conda activate tv
```

Clone and set up the xr_teleoperate repo as well as the different configuration files : 

```bash
cd ~
git clone https://github.com/y-hadj/xr_teleoperate.git
cd ~/xr_teleoperate
git submodule update --init --depth 1 && pip install -r requirements.txt
(cd teleop/teleimager && pip install -e . --no-deps)
(cd teleop/televuer && pip install -e .)
(cd teleop/robot_control/dex-retargeting && pip install -e .)
pip install "params-proto==2.13.2"
```

Clone the unitree SDK2_Python, skip if it is already installed : 

```bash
cd ~ 
git clone https://github.com/unitreerobotics/unitree_sdk2_python.git  
(cd unitree_sdk2_python && pip install -e .)
```

Enable the communication with the Meta Quest / Pico VR device : 

```bash
cd ~/xr_teleoperate/teleop/televuer
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout key.pem -out cert.pem -subj "/CN=xr-teleoperate"
mkdir -p ~/.config/xr_teleoperate && cp cert.pem key.pem ~/.config/xr_teleoperate/ && sudo ufw allow 8012
```

Set up the connexion between the laptop and the PC2 : 


```bash
cd ~/xr_teleoperate
./connect_ethernet.sh && ssh-copy-id unitree@192.168.123.164
./setup_network.sh --off                     # PC2 needs internet for its install
scp teleop/televuer/{cert,key}.pem unitree@192.168.123.164:~/.config/xr_teleoperate/
```

If the following error appears : *"/usr/bin/ssh-copy-id: ERROR: No identities found"*, then create a ssh key and transfer it into the G1 : 
```bash
ssh-keygen -t ed25519
ssh-copy-id unitree@192.168.123.164
```

## PC2 Setup (`ssh unitree@192.168.123.164`)

Install and setup miniconda : 

```bash
unset PYTHONPATH
mkdir -p ~/miniconda3 && wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh -O ~/miniconda3/miniconda.sh
bash ~/miniconda3/miniconda.sh -b -u -p ~/miniconda3 && rm ~/miniconda3/miniconda.sh
source ~/miniconda3/bin/activate && conda init bash
conda config --set auto_activate false       # conda available, but no (base) at each login
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
```

Then, the virtual environment is created via : 

```bash
conda create -n teleimager python=3.10 -y && conda activate teleimager
```

Clone the teleimager repo on the PC2 and install the dependencies : 

```bash
sudo apt install -y libusb-1.0-0-dev libturbojpeg-dev
cd ~ && git clone https://github.com/unitreerobotics/teleimager.git && cd teleimager
git checkout 57cf2a40572227273fa001cd17833b755331ec97
pip install -e ".[server]" psutil && bash setup_uvc.sh    # "uvcvideo is in use" is expected; then re-login
```

If PC2 cannot resolve hostnames: 

```bash
sudo mkdir -p /run/resolvconf && printf 'nameserver 8.8.8.8\n' | sudo tee /run/resolvconf/resolv.conf
```

**Camera config** — edit `~/teleimager/cam_config_server.yaml` on PC2:
```yaml
head_camera:            # keep enable_*/port/codec keys as they are
  type: opencv
  image_shape: [480, 640]
  binocular: false
  fps: 30
  video_id: 4           # RealSense colour stream (/dev/video2 is infrared)
  serial_number: null
  physical_path: null
```
```bash
sed -i '/^left_wrist_camera:/,$ { s/enable_zmq: true/enable_zmq: false/; s/enable_webrtc: true/enable_webrtc: false/ }' ~/teleimager/cam_config_server.yaml
```

**Hotspot** — laptop, while it still has internet: `./setup_network.sh`

## Each session

> Debug mode (no `--motion`): the robot cannot balance — **hang it on the gantry**, keep people clear.

| # | Where | Action |
|---|---|---|
| 1 | Laptop | Ethernet plugged in (./connect_ethernet.sh) and note <eth-iface>, Wi-Fi on `G1-Hotspot` (./setup_network.sh); `ip -4 -br addr` and note `LAPTOP_IP` |
| 2 | Quest / Pico | Wi-Fi `G1-Hotspot`; hand tracking on |
| 3 | Laptop | `conda activate tv && python ~/g1_ws/innov8/xr_teleoperate/g1_videohub.py off <eth-iface>` (frees the camera; redo after each robot reboot) |
| 4 | PC2 | `unset PYTHONPATH && conda activate teleimager && cd ~/teleimager && teleimager-server` |
| 5 | Laptop | see command below |
| 6 | Quest / Pico Browser | `https://192.168.123.164:60001` → Advanced → Proceed → **Start** |
| 7 | Quest / Pico Browser | `https://LAPTOP_IP:8012/?ws=wss://LAPTOP_IP:8012` → Advanced → Proceed → **Virtual Reality** |
| 8 | Laptop | Match the robot's arm pose, press **r** · **s** record (with `--record`) · **q** quit (arms home first) |
| 9 | Robot | Reboot after a debug-mode session |

```bash
cd ~/xr_teleoperate/teleop
python teleop_hand_and_arm.py --arm=G1_29 --input-mode=controller --display-mode=ego --network-interface=<eth-iface> --img-server-ip=192.168.123.164
```

Options: `--ee=dex3|dex1|dex1_internal|inspire_dfx|inspire_ftp|brainco` (if hands fitted) · `--input-mode=controller` · `--record` · `--motion` (robot standing in R1+X mode).