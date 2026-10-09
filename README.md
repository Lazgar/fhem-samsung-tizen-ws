# fhem-samsung-tizen-ws

FHEM module `SamsungTizenWS` for Samsung Smart TVs with **Tizen** (about 2016 and newer). It uses the secure remote WebSocket (port 8002) with token pairing, the same protocol the Samsung SmartThings/remote apps and Home Assistant's `samsungtv` integration use.

* **Pairing without typing a token:** the first connection makes the TV show an "allow" dialog. After you confirm it with the TV remote the TV returns a token, which the module keeps in the FHEM key store.
* Remote keys (`set tv volumeUp`, `set tv key KEY_HOME`, sequences `set tv keys KEY_HOME,KEY_RIGHT,KEY_ENTER`), **launch apps** by name or id, read the list of installed apps.
* Power state from the TV's REST info API (`on`, `standby`, `off`), power on through Wake-on-LAN, power off with `KEY_POWER`.
* Non-blocking (HttpUtils/DevIo), reconnects by itself, back-off after a denied pairing.

Not possible with the local API of these models: reading the volume as a number (only volume up/down keys). Older TVs (e.g. the 2018 Q7) do not send `ms.channel.ready`; the module works with both.

## Installation

```
update add https://raw.githubusercontent.com/Lazgar/fhem-samsung-tizen-ws/main/controls_SamsungTizenWS.txt
update all
```

## Setup

```
define tv SamsungTizenWS 192.168.1.40
attr tv wolMac aa:bb:cc:dd:ee:ff
```

1. Switch the TV on, then define the device. The TV shows a dialog ("allow FHEM?") - confirm it with the TV remote.
2. `wolMac` is the MAC address of the TV's **network** interface (LAN cable or Wi-Fi, whichever the TV uses); the TV setting "Power on with mobile device" (network standby) must be enabled for `set tv on`.
3. If you denied the dialog or want to pair again: `set tv pairingReset` (it also deletes the stored token).

If the TV does not show a dialog, check *Settings → General → External Device Manager → Device Connection Manager → Access notification* (menu names differ by model/year).

## Set / get / attributes / readings

| | |
|---|---|
| set | `on`, `off`, `power`, `key <KEY_...>`, `keys KEY_A,KEY_B`, short commands (`volumeUp volumeDown mute channelUp channelDown up down left right ok back home menu source info exit play pause stop`), `app <name or appId>`, `refreshApps`, `pairingReset` |
| get | `info` (device data of the TV), `apps` |
| attr | `interval` (REST poll, default 30 s, min 5), `clientName` (name shown on the TV), `restPort` (8001), `wolMac`, `wolBroadcast`, `wolPort`, `keyDelay` (ms between keys of `keys`), `disable` |
| readings | `state` (off, standby, on, pairing, connecting, connected, disabled), `presence`, `power`, `tokenState`, `modelName`, `tvName`, `resolution`, `os`, `networkType`, `lastKey`, `lastApp`, `apps`, `appCount`, `lastWol` |

## Tests

`python3 tests/run_tests.py [--fhem /opt/fhem]` starts a mock TV (`tests/mock_tv.py`: REST API, TLS WebSocket with token pairing, Wake-on-LAN listener) and a throw-away FHEM instance (own ports and directory; the production FHEM is only read) and checks pairing, keys, apps, power, Wake-on-LAN, standby, denied pairing and attributes (38 checks).

## License

GPL-2.0-or-later (see LICENSE).
