# Hotspot Fallback

Automatically enables a Wi-Fi hotspot if the normal Wi-Fi connection is lost.

## Use Case

Imagine you have a computer or robot running Linux or Raspberry Pi OS. It’s normally accessible via SSH over Wi-Fi.

If you bring it somewhere without a known Wi-Fi network, you'll lose access. This project solves that: when the device can’t connect to a configured Wi-Fi network, it automatically switches to hotspot mode. When Wi-Fi comes back, the hotspot shuts off and reconnects normally.

## Installation

Follow the instructions in the [setup guide](https://dominique-clause.com/en/blog/hotspot-fallback).

## Usage

### Automatic

Once installed properly, everything runs automatically. No manual action is needed.

### Manual

If you want to manually control the hotspot:

**Start the hotspot:**
```shell
/your/path/hotspot_switcher.sh start
```

**Stop the hotspot and restore original connexion:**
```shell
/your/path/hotspot_switcher.sh stop
```