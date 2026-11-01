# GymCam — aesthetic gym camera for iPhone 15 Pro Max

## Install from a Windows PC (free)

You need: a free GitHub account, a free Apple ID, the iPhone's USB‑C cable.

### 1. Build the app in the cloud (GitHub)
1. Go to **github.com** → sign up / log in.
2. Click **+** (top right) → **New repository** → name it `GymCam` → choose **Public** (free cloud Mac minutes) → **Create repository**.
3. On the new repo page click **uploading an existing file**.
4. Unzip `GymCam.zip` on your PC, open the `GymCam` folder, select **everything inside it**
   (`.github`, `GymCam`, `GymCam.xcodeproj`, `README.md`) and drag it into the browser. Click **Commit changes**.
   - If the `.github` folder doesn't upload: in the repo click **Add file → Create new file**, type the name
     `.github/workflows/build-ipa.yml`, paste the content of that file from the zip, and commit.
5. Open the **Actions** tab. A build named **Build GymCam** starts by itself (if not: click it → **Run workflow**).
   It takes ~5–10 minutes. Green check = done.
6. Click the finished run → at the bottom under **Artifacts**, download **GymCam-ipa**. Unzip it → you get `GymCam.ipa`.

### 2. Put it on your iPhone (Sideloadly)
1. On Windows install **iTunes from apple.com** (not the Microsoft Store version) — Sideloadly needs its drivers.
2. Install **Sideloadly** from sideloadly.io.
3. Plug in the iPhone, unlock it, tap **Trust this computer**.
4. Open Sideloadly → drag `GymCam.ipa` in → enter your Apple ID email → **Start** → enter the password / code when asked.
5. On the iPhone: **Settings → General → VPN & Device Management** → tap your Apple ID → **Trust**.
6. **Settings → Privacy & Security → Developer Mode → On** (iPhone restarts), then open GymCam.

With a free Apple ID the app works for **7 days**; after that, just repeat step 2.4 (videos you made stay in Photos).
A paid Apple Developer account ($99/yr) gives 1 year instead.

## Install from a Mac
Open `GymCam.xcodeproj` in Xcode → click **GymCam** target → **Signing & Capabilities** → pick your Team (Apple ID) →
plug in the iPhone → press **Run**. If Xcode says the bundle ID is taken, change it to anything unique.

## Using it at the gym
- **Volume buttons** start/stop recording (great when the phone is on a tripod).
- **Self-timer** (top-left menu): 3 s or 10 s to walk to the bench.
- **Looks:** Moody, Steel, Warm Film, Noir, Clean — the grade is baked into the video.
- **Slider button (bottom-left):** Exposure, manual white balance (Warmth/Tint), Film FX (grain + vignette).
- **Tap** to focus/expose, **long-press** or the **lock button** to lock it (so the camera stops "breathing" when you move).
- Lenses: .5 / 1x / 2x / 5x. Videos save to Photos as 9:16 vertical.

### Lighting tips
- Gyms are dim: use **24 or 30 fps** for a brighter, cleaner image. Use 60 fps only in bright areas.
- Use **1x or 2x** — they have the best sensor. 5x gets noisy in low light.
- Gym tubes look green? Turn off Auto WB and drag **Tint** to the left a bit; drag **Warmth** up for a golden vibe.
- Put a strong light (window, ring light) to the side of you, not behind you. Lower Exposure a little for the moody look.
- 4K + Film FX is heavy: if the phone gets hot, switch to 1080p.
