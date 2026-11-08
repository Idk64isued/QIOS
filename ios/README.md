# Light Touch on iOS: getting a device onto the phone

The Mac app ships a ready-made iPod touch 2G (iOS 3.1.3) as a packed folder, so nothing has to be prepared.

1. Download the latest Mac release from github.com/samhenrigold/LightTouchMac/releases and unzip it (works on Linux).
2. Inside it, open `Light Touch.app/Contents/Resources/Device/`. It holds `n72ap-7E18.itbase` (a folder), the SecureROM files
   `bootrom_240_4` and `ipod1g/bootrom_s5l8900`.
3. Copy that whole `Device` folder to the phone: Files > On My iPhone > LightTouch > Device (the app makes the folder on first
   launch). Over the local network from the Deck: `cd` into the folder, `python3 -m http.server 8000`, open
   `http://<deck-ip>:8000` in Safari and download each file; a folder is easier as a zip (`zip -r Device.zip .`).
4. In the app: Packed devices > Unpack n72ap-7E18. It unpacks on the phone (the NAND image is sparse, so it takes little space).
5. Enable JIT with StikDebug (script: universal.js), open the app, then tap the device under Devices.

On a PC/Linux machine you can also unpack there with `ios/tools/unpack_itbase.py` (same result, but a copied NAND image loses
its holes and gets big, so unpacking on the phone is better).

Not done by either path: the per-install identity reseed and the language seed. The packed device is en-US and boots with the
identity it was packed with.
