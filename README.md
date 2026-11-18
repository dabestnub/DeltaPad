# DeltaPad

DeltaPad turns your iPhone into a customizable controller for the Delta emulator on your Mac. It connects through Bluetooth or local Wi-Fi and supports NES / GBC, GBA, SNES / DS, and N64 control layouts.

Move and resize controls, choose colors, adjust haptic feedback, and export or import your controller settings. The DS layout includes a touchpad for controlling the Mac cursor. The N64 joystick sends eight keyboard directions rather than variable analog input.

## How to use

1. Install the DeltaPad iPhone app with your sideloading app or LiveContainer, and open DeltaPadMac on your Mac.
2. Allow Bluetooth and camera access when prompted. For Wi-Fi connections, also allow Local Network access.
3. In the Mac companion, click **Allow controller input** and enable DeltaPadMac in **System Settings → Privacy & Security → Accessibility**.
4. On your iPhone, choose **Bluetooth** or **Wi-Fi**, tap **Scan QR code**, and scan the code displayed by the Mac companion. Bluetooth works without a hotspot. Wi-Fi requires both devices to be on a network that allows them to communicate.
5. Choose your console layout on the phone. In Delta, select **Keyboard** for Player 1 and assign the keys shown in the Mac companion for that console.
6. Bring Delta’s game window to the front and play using your phone. Keep Delta on the Mac’s main display when using the touchpad.

### Customize controls

Tap **Customize controls**, then drag a control to move it. Select a control to change its size, color, or opacity in the floating inspector. Enable **Snap to grid** to align controls, and tap **Save** when finished. Layouts are saved separately for each console group.

Use the inspector’s **Haptics** tab to enable feedback and adjust its strength. In the SNES / DS layout, use **DS touchscreen** in the system menu to show or hide the touchpad. Slide on the touchpad to move the cursor, tap to click, or hold briefly and slide to drag.

### Export and import configs

Open **⋯ → Export controller configs** to save your layouts and settings as a JSON file. Use **Import controller configs** to load a saved file. Importing asks before replacing all saved console layouts, colors, haptic settings, and grid preferences.

### Disconnect or reconnect

Open **⋯ → Disconnect** on the phone, or click **Disconnect** in the Mac companion. To reconnect, scan the Mac’s current QR code again.

If pairing succeeds but controls do not respond, check the Mac companion’s input status, confirm Accessibility permission, and bring Delta’s game window to the front. If Bluetooth is unavailable, enable Bluetooth on both devices and check Bluetooth permissions for DeltaPad or LiveContainer on the phone and DeltaPadMac on the Mac.
