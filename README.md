# VoxLibre for iOS

A SwiftUI/CoreBluetooth port of [VoxLibre](https://github.com/elvisoliveira/voxlibre)
(the offline Android companion for the Vocci ring). Same protocol, same features:

- **Ring**: device info, battery, storage, signal, button events and gestures. On the Ring tab
  you choose what a single click, double click and hold do: talk to the agent, stop it,
  play/pause or skip in the Music app, or nothing.
- **Recordings**: on-ring and downloaded clips, download, decode and play, share or
  save to Files, delete on the ring or on the phone.
- **Logs**: live TX/RX of the BLE protocol, an "unmapped only" filter, and sharing.
- **Agent** (AI, optional): chat by text, or hands-free by voice through AirPods. It can search
  your recordings, remember things, and optionally hand jobs to your own house agent.

The ring itself never touches the cloud. The AI features are optional. With them on,
transcription still runs on the iPhone (Apple SpeechAnalyzer), but transcripts and chats go to
the Claude API (`claude-opus-5-5`) using your own API key, and, if you add an OpenAI key, spoken
replies are voiced by OpenAI. Requires iOS 26 or later.

## AI features

- **Pipeline**: when the ring makes a new recording, the app downloads it, transcribes it on
  the iPhone, and asks Claude for a title, summary, speakers, insights, decisions, action items
  and memories. You can turn each step off under Settings › AI & voice.
- **Speakers**: on-device recognition doesn't tell voices apart, so Claude labels each line from
  context. You can tap a speaker to correct the name.
- **Memory**: facts the agent saves from recordings and chats, stored on the phone in
  `Application Support/VoxLibre/memory.json`. You can view, add, edit or delete them from the
  brain icon on the Agent tab.
- **Voice**: map a ring input to *Talk to the agent* (hold by default); replies play through
  your AirPods, read by OpenAI's natural `gpt-4o-mini-tts` voice with your own OpenAI key (only the
  reply text is sent; you can pick the voice and describe how it should sound). Without a key or
  a connection, the on-device Apple voice reads instead. By default the gesture only works while headphones are connected. Two mics:
  - *AirPods mic*: a back-and-forth conversation that listens again after each reply until you
    go quiet. Only while VoxLibre is open, because iOS doesn't let apps start the mic in the
    background.
  - *Ring mic*: push-to-talk. The ring has no live audio stream, so you hold it while you speak,
    then the clip is downloaded, transcribed on the phone and answered. It takes a few seconds
    longer, but it works with the phone locked. These clips get a transcript but no analysis.
  - *Auto* (default) uses the AirPods mic while the app is open and the ring mic otherwise.
- **House agent** (optional): see below.
- **Refusal fallback**: Claude requests set `fallbacks: "default"`. If a safety filter declines
  a request, the API retries it on a fallback model.

### House agent (optional)

If you run your own home assistant, the ring agent can hand it jobs ("turn off the lights",
"add milk to the shopping list"), and each action item gets a **Send** button. Under
Settings › AI & voice › House agent, enter a name, an `https://` address and an access token.
The agent's `ask_house_agent` tool then calls:

```
POST <address>/api/ring/ask
Authorization: Bearer <access token>
Content-Type: application/json

{"message": "turn off the living room lights"}
```

It expects `200 {"answer": "Done, they're off."}` back. Any other status counts as an error,
and an `{"error": "..."}` body is shown to you. Use a long random token that only allows this
one request, and HTTPS only (the app refuses plain HTTP). The token is stored in the iPhone's
Keychain.

For a personal build, put your assistant's name, address and abilities in
`VoxLibre/AI/HouseAgentDefaults.swift`. Only that file then differs from this repo, so
upstream updates merge cleanly. Keep the token out of the code; enter it in the app.

## Credits

Port of [VoxLibre](https://github.com/elvisoliveira/voxlibre) by Elvis Oliveira (Android).
The protocol, auth handshake and recording format come from that project. Not affiliated with
Vocci.

## Run it on your iPhone

The simulator has no Bluetooth, so you need a real device.

1. Open `VoxLibre.xcodeproj` in Xcode.
2. Go to the **VoxLibre** target, then **Signing & Capabilities**, and pick your
   **Team**. A free Apple ID works. If the bundle ID `app.voxlibre.ios` is taken,
   change it.
3. Select your iPhone and press Run. On a free account, trust the developer profile
   under Settings › General › VPN & Device Management.
4. In the app, tap the gear icon and fill in **BIND KEY** and **USER ID**. These are the
   same server-minted values the Android app needs. Then tap **Choose**, pick the ring,
   tap **Save**, and tap **Connect**.

## iOS-specific differences

| Android | iOS |
|---|---|
| Picks the ring by MAC from bonded devices | Scans nearby, and the ring is stored by the UUID iOS assigns to it |
| Uses the MAC in the HMAC auth | iOS hides MACs, so the app reads it from the ring's `0x80` device-info frame and keeps the spelling that verifies the ring's own HMAC. If auth fails, enter the MAC manually under Settings › Advanced |
| MediaCodec Opus decode | Apple's built-in Opus decoder (`AVAudioConverter`), then a WAV cache |
| System-wide media key | iOS doesn't allow that, so the single click toggles the **Music** app only |
| SharedPreferences | Keychain for the credentials, UserDefaults for the rest. Recordings go in Documents (Files › On My iPhone › VoxLibre) |

Background mode `bluetooth-central` is enabled, so button events keep arriving while
the app is in the background, as long as iOS keeps the app alive.

## Troubleshooting

Check the **Logs** tab first.

- **`verifyRing=false`**: the BIND KEY is wrong, or the MAC couldn't be detected.
  Enter the ring's MAC (`AA:BB:CC:DD:EE:FF`) under Settings › Advanced. You can find
  it in the Bluetooth settings of the Android phone that's paired with the ring.
- **`notify … failed` / pairing prompt**: the ring requires an encrypted link. Accept
  the iOS pairing prompt. If the ring only allows one bonded phone, forget it on the
  other phone first.
- **The ring doesn't show in the picker**: wake it, keep it close, and turn on
  "Show unnamed devices".
