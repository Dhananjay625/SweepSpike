# 360_app — Phone-Only 3D Space Capture (Matterport-style)

**v2 — revised 2026-08-04** after research into Matterport's actual pipeline.
Supersedes v1 (which was LiDAR-mesh-first; see `docs/adr/` note in §10 and CHANGELOG).

Cross-platform (iOS + Android) mobile app that replaces a 360° camera: the user photographs a room
from guided angles at several standing positions, and the app produces an immersive walkable 360°
tour with measurement capability.

**Constraints:** solo developer · $0/month infrastructure at start · both platforms ·
measurement/insurance use case (metric accuracy matters and must be honestly labelled).

---

## 1. How Matterport actually works (research summary)

This is the model we are replicating, so every build decision refers back to it.

1. **Capture is stop-and-shoot at discrete "sweep" points, not continuous scanning.** The operator
   stands still, captures a full 360° panorama, walks 5–8 ft (1.5–2.5 m), repeats. The app
   auto-aligns each new sweep against previous ones and draws a live minimap of coverage.
   ([Scan2CAD capture basics](https://www.scan2cad.com/blog/cad/matterport-capture-basics/),
   [Matterport Assisted Alignment](https://support.matterport.com/hc/en-us/articles/115007423487-Assisted-Alignment))
2. **With a phone, the panorama comes from rotating in place** while the app fires frames at guided
   angles and stitches them.
   ([Matterport Capture for iOS](https://support.matterport.com/hc/en-us/articles/1500004898402-Matterport-Capture-for-iOS))
3. **Processing stitches each sweep into a "skybox," estimates 6-DoF pose per panorama with global
   bundle adjustment, and reconstructs one textured mesh.**
   ([Matterport3D paper, §2](https://arxiv.org/pdf/1709.06158))
4. **Depth is inferred by a neural network (Cortex), not computed by photogrammetry.** Cortex is
   trained on Matterport's proprietary library of paired panorama+LiDAR scans; ARKit/ARCore pose
   data anchors metric scale.
   ([Cortex AI](https://matterport.com/cortex-ai),
   [Geo Week on Cortex](https://www.geoweeknews.com/articles/matterport-cortex-gets-quick-3d-from-360-photos-using-ai-and-computer-vision/),
   [Geo Week on smartphone capture](https://www.geoweeknews.com/articles/matterport-announces-3d-capture-and-smart-measurement-for-smartphones-using-ai/))
5. **The "tour" is mostly panoramas.** Walkthrough = hopping between skyboxes with mesh-rendered
   transitions; the mesh drives dollhouse view, floor plan, and measurements — not the primary
   visual. ([Matterport3D paper](https://arxiv.org/pdf/1709.06158),
   [360°→3D conversion](https://support.matterport.com/hc/en-us/articles/360026831293-How-to-Convert-a-360-View-to-a-3D-Scan-))

**Their moat is training data, not algorithms.** Every pipeline stage now has an open-source
equivalent ([Panomity's open pipeline](https://panomity.com/virtual-reality-blog/matterport-alternative-3d-tours-360-photos/),
[PanoFormer](https://arxiv.org/pdf/2203.09283), [HoHoNet](https://arxiv.org/pdf/2011.11498),
[Depth Anything V2](https://github.com/DepthAnything/Depth-Anything-V2)).

**Why this beats the v1 LiDAR plan for this product:** works on any phone (no LiDAR gate, so iOS
and Android are equal citizens — your requirement); panorama tours look photo-real immediately;
ML depth/mesh layers on later without reshooting, because sweeps + poses are already stored.

---

## 2. Architecture

```
[Phone app — Flutter shell + native AR capture module]
   guided rotate-in-place capture at each sweep point (inside AR session → poses)
   on-device stitch → equirectangular JPEG per sweep
   store sweep poses (metric, from VIO) + IMU/heading
   upload: panoramas + poses.json          (~2-4 MB/sweep, not raw frames)
        │
[Supabase — Postgres + Auth + Storage + RLS + Edge Functions]
   scan/sweep metadata, share tokens, signed URLs
        │
[Processing — Phase B+, runs on local M2 first, cloud later]
   depth inference per panorama (Depth Anything V2 / PanoFormer)
   scale anchoring from VIO poses → fused mesh → Draco glTF
        │
[Web viewer — React + Vite + Three.js on Vercel]
   Phase A: skybox tour (pano hop + minimap)
   Phase B: measurements from depth; Phase C: dollhouse mesh
```

| Decision | Choice | Why / source |
|---|---|---|
| Capture model | Discrete sweeps, 1.5–2.5 m apart | Matterport's proven UX; alignment breaks beyond ~8 ft ([Assisted Alignment](https://support.matterport.com/hc/en-us/articles/115007423487-Assisted-Alignment)) |
| Capture runs inside AR session | ARKit `ARSession` / ARCore `Session` | VIO gives metric camera poses — the only free source of absolute scale; monocular photos alone have none ([ARKit docs](https://developer.apple.com/documentation/arkit), [ARCore docs](https://developers.google.com/ar)) |
| App shell | Flutter; native Swift/Kotlin capture screens via platform views | AR APIs have no trustworthy cross-platform wrapper; shell (~85% of app) is shared |
| Stitching | On-device: project frames to equirect using AR poses; OpenCV stitcher as fallback | Poses make stitching near-deterministic vs. feature-matching blind ([OpenCV stitching](https://docs.opencv.org/4.x/d1/d46/group__stitching.html)) |
| Depth (Phase B) | Depth Anything V2 (per-face on cubemap) or PanoFormer (native equirect) | Open weights, strong indoor results ([DA-V2](https://github.com/DepthAnything/Depth-Anything-V2), [PanoFormer](https://arxiv.org/pdf/2203.09283)) |
| Formats | Equirect JPEG (sweeps), glTF/GLB+Draco (mesh) | Web-native, compact ([glTF spec](https://registry.khronos.org/glTF/), [Draco](https://github.com/google/draco)) |
| Backend | Supabase free tier | Auth+Postgres+Storage+RLS in one, $0, plain-Postgres exit path ([Supabase pricing](https://supabase.com/pricing)) |
| Viewer | Three.js | Best pano/glTF ecosystem ([three.js](https://threejs.org/docs/)) |
| Hosting | Vercel free tier | ([Vercel pricing](https://vercel.com/pricing)) |

Rejected: Unity/AR Foundation (game engine tax for an app that's mostly forms; weak WebGL viewer
export), React Native (weaker platform-view embedding of live AR camera), WebXR capture (no
reliable camera+pose access in browser), cloud COLMAP photogrammetry (violates $0; no absolute
scale; deferred to paid "HQ mode" — [COLMAP](https://colmap.github.io/)).

---

## 3. Phased scope

- **Phase A — Tour MVP (ship this):** guided sweep capture → stitched panoramas → upload → web
  skybox tour with sweep-hop navigation + minimap + share links. Zero ML. Works on any phone.
- **Phase B — Measurement:** depth inference per sweep on the M2, VIO-scaled; point-to-point
  measurement in the viewer with tolerance bands.
- **Phase C — Dollhouse:** fuse depth maps into one textured mesh; dollhouse/floor-plan view;
  smooth mesh-based transitions between sweeps.
- **Out entirely (post-MVP):** VR, collaboration, AI room labelling, floor-plan export, teams,
  offline sync, cloud GPU processing.

**Phase A acceptance:** capture a 4-sweep room in <5 min on a mid-range Android AND an iPhone;
share link opens in <3 s; pano hop feels instant; a stranger completes a capture unaided.
**Phase B acceptance:** wall measurement within ~5% of tape measure, tolerance shown in UI.

---

## 4. Data model

```
users          (Supabase Auth)
scans          id, user_id, name, status, captured_at, device_model,
               capture_method ('sweep_pano'), accuracy_class, sweep_count
sweeps         id, scan_id, seq, pano_key,            -- storage key of equirect JPEG
               pose_t[3], pose_q[4],                  -- VIO position (m) + orientation
               floor_height_m, depth_key NULL         -- Phase B depth map
measurements   id, scan_id, label, point_a[3], point_b[3], distance_m, tolerance_m
shares         id, scan_id, token, expires_at, revoked_at
```

RLS: row readable iff `user_id = auth.uid()` OR valid unexpired share token. Edge functions:
`POST /scans/:id/finalize` (validate uploads, thumbnail), `POST /scans/:id/share` (mint token).
Sweep poses are the crown jewels — they are what lets Phase B/C exist without reshooting.

---

## 5. Build order — every step

Each iteration ends demonstrable. Do not start the next until the current one runs.

### Iteration 0 — Capture spike (go/no-go, ~1 week equivalent)
Goal: prove rotate-in-place capture + pose-guided stitching yields an acceptable panorama on YOUR
phones. Everything depends on this.
1. Bare iOS app: `ARSession` (world tracking), record camera frames + `ARCamera.transform` while
   user rotates in place following on-screen yaw targets (e.g. every 30° × 2 pitch rings ≈ 24
   frames). ([ARKit ARCamera](https://developer.apple.com/documentation/arkit/arcamera))
2. Project frames into an equirectangular canvas using the recorded poses (sphere reprojection);
   fallback: OpenCV `Stitcher` in spherical mode.
3. Same spike on Android with ARCore `Session` + `Camera.getPose()`.
   ([ARCore pose](https://developers.google.com/ar/reference/java/com/google/ar/core/Camera))
4. Inspect: seam quality, exposure consistency (lock AE/AWB during sweep), parallax ghosting from
   hand-held rotation (the phone rotates about the hand, not the lens nodal point — expect ghosting
   on near objects; acceptable threshold is a judgment call made HERE).
5. Walk 2 m, capture a second sweep, check VIO translation between sweeps against tape measure —
   this is the future measurement scale anchor. Record the error.
**Gate:** panoramas look acceptable and inter-sweep VIO distance error <3% → proceed. Else pivot to
requiring the user's phone be placed on a cheap tripod/rotator, or license a stitching SDK.

### Iteration 1 — iOS capture module (production quality)
1. Guided capture UI: yaw/pitch target reticle, auto-fire when aligned (like Google Street View
   app), progress ring, redo-frame.
2. Exposure/white-balance lock per sweep; HDR bracket if trivially available.
3. Stitch on background thread; live preview of growing panorama.
4. Sweep-to-sweep flow: "walk 2 m" prompt, live minimap plotting VIO positions of completed sweeps,
   coverage warning if sweeps too far apart (>2.5 m, per Matterport's rule).
5. Persist locally: `scan/` dir with pano JPEGs + `poses.json` (schema in §4); crash-safe resume.
6. Export/import contract documented — this exact contract is what Android must also produce.

### Iteration 2 — Backend
1. Supabase project (EU/UK region — GDPR §7); SQL migrations for schema + RLS from §4.
2. Auth: email magic-link (no password flows to build).
3. Storage buckets `panos/`, `thumbs/`, `depth/`; signed-URL upload from app.
4. Edge functions `finalize` + `share`; RLS tests (each policy has a pgTAP test —
   [pgTAP](https://pgtap.org/)).

### Iteration 3 — Flutter shell
1. Scaffold: auth screens, scan list (name/date/thumbnail/status), settings, delete.
2. Embed iOS capture via platform view + method channel (contract: `startScan`, `sweepComplete`
   events, `finishScan` → local path list).
3. Upload queue: background, resumable, retry with backoff, wifi-preferred toggle, progress UI.
4. Full loop demo: sign in → capture → upload → listed with thumbnail.

### Iteration 4 — Web viewer (completes Phase A)
1. Vite + React + TS scaffold; Three.js scene; load equirect pano onto inverted sphere
   ([three.js pano example](https://threejs.org/examples/#webgl_panorama_equirectangular)).
2. Look controls (drag/touch/gyro), FOV zoom, sweep hotspots placed from `poses.json` positions
   projected into the current pano; click → crossfade to neighbour sweep.
3. Minimap from sweep positions; keyboard/tap navigation.
4. Share-link route resolving token → signed URLs; private-by-default.
5. Progressive loading: low-res pano first, tiles/full-res after
   (basis: skybox tiling as Matterport does — [Matterport3D](https://arxiv.org/pdf/1709.06158)).
6. Perf pass: <3 s first pano on 4G, 60 fps look-around on mid-range phone.
**→ SHIP Phase A here: TestFlight + a handful of real users.**

### Iteration 5 — Android capture
1. Kotlin module: ARCore session, same guided-capture UX, same stitch pipeline, same on-disk
   contract as Iteration 1 step 6.
2. Device-quality gate: require ARCore-certified device
   ([supported list](https://developers.google.com/ar/devices)); label `accuracy_class` lower
   where VIO check (Iteration 0 step 5, rerun per device class) is worse.
3. Play internal-track release.

### Iteration 6 — Phase B: depth + measurement
1. Offline experiment on captured sweeps (M2, Python): Depth Anything V2 on cubemap faces vs.
   PanoFormer on equirect; compare wall distances against tape ground truth.
   ([DA-V2](https://github.com/DepthAnything/Depth-Anything-V2),
   [PanoFormer](https://arxiv.org/pdf/2203.09283))
2. Scale calibration: solve per-sweep metric scale by aligning predicted relative depth with known
   VIO baselines between sweeps (and floor-plane height as a second constraint).
3. Package as a job: `tools/depth_worker` pulls unprocessed sweeps from Supabase, runs on the M2,
   uploads `depth_key` maps. (Cloud GPU only when revenue exists.)
4. Viewer measurement tool: raycast into depth map, point-to-point distance, tolerance band from
   `accuracy_class` — never display false precision.
**Gate:** ~5% wall accuracy → advertise measurement; worse → keep it labelled "estimate".

### Iteration 7 — Phase C: dollhouse (only after B validates)
1. Fuse per-sweep depth into TSDF volume (Open3D), extract mesh, texture from panos, Draco-compress
   to GLB. ([Open3D TSDF](http://www.open3d.org/docs/latest/tutorial/pipelines/rgbd_integration.html))
2. Dollhouse orbit view + mesh-rendered sweep transitions in viewer.

### Iteration 8 — Hardening & launch
Error states, poor-capture detection (blur/exposure/coverage), telemetry (Sentry free tier),
delete-account + data-export (GDPR), privacy policy, App Store / Play submission, docs.

---

## 6. Repository structure

```
360_app/
├── mobile/
│   ├── app/               # Flutter shell
│   ├── ios_capture/       # Swift: ARKit guided capture + stitch → contract
│   └── android_capture/   # Kotlin: ARCore ditto
├── web/                   # React+Vite+Three.js viewer
├── supabase/{migrations,functions}/
├── tools/depth_worker/    # Phase B: M2-run depth inference
├── docs/adr/              # decision records (ADR-001: sweep pivot)
└── CHANGELOG.md
```

---

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Hand-held rotation parallax → stitching ghosts | Ugly panos, MVP quality | Iteration 0 measures it; UX coaches "pivot phone about the camera, elbows in"; near-object warning; tripod-adapter fallback |
| VIO drift between sweeps | Measurement scale error | Keep sweeps ≤2.5 m apart; re-anchor with ARKit/ARCore relocalisation; record + surface per-scan error class |
| Depth-inference accuracy short of measurement claims | Phase B fails | Phase A ships without it; Iteration 6 gates the claim; "estimate" labelling as fallback |
| Android device variance (VIO quality, camera control) | Two-tier quality | ARCore-certified allowlist + per-class accuracy labels |
| Supabase/Vercel free-tier ceilings | Hard stop ~1 GB storage | Fine for beta; exit path is plain Postgres + R2 |
| GDPR (home interiors, bystanders) | Legal exposure (UK user base) | EU/UK region, delete/export flows in Iteration 8, consent copy at capture, raw frames never uploaded |
| Matterport patents (they hold many on capture/alignment UX) | Low prob., high impact | Distinct UX details, measurement-niche positioning; patent review before commercial launch |
| Solo scope creep | Never ships | Phase gates are commitments; Phase A alone is a complete product |

---

## 8. Cost

$0/month infra (Supabase free, Vercel free, M2 for Phase B compute).
Unavoidable: **Apple Developer Program $99/yr** (physical-device AR builds + App Store).
Google Play one-time $25. First paid upgrade only at real usage: Supabase Pro ~$25/mo.

---

## 9. Success metrics

Phase A: 10 external users complete an unaided capture; share-link open rate >50%; capture
abandonment <20%. Phase B: measured-vs-tape error ≤5% on 20 test walls across ≥3 device models.

---

## 10. Changes from v1

v1 planned LiDAR-first live mesh scanning. Replaced by sweep-panorama capture because (a) the
user's stated goal is replacing 360° cameras with the Matterport photo workflow, (b) it removes
the LiDAR hardware gate making Android first-class, (c) Phase A needs zero ML and ships fastest.
LiDAR remains an accuracy bonus on Pro iPhones (better VIO + optional depth), not a requirement.
COLMAP photogrammetry remains deferred to a future paid HQ mode.

## 11. Immediate next step

Iteration 0, step 1: the iOS capture spike. Then its Android twin. Both produce one number each
(stitch quality judgment + VIO distance error) that gate everything else.

## Sources

- Matterport3D: Learning from RGB-D Data in Indoor Environments — https://arxiv.org/pdf/1709.06158
- Matterport Cortex AI — https://matterport.com/cortex-ai
- Geo Week: Cortex quick 3D from 360° photos — https://www.geoweeknews.com/articles/matterport-cortex-gets-quick-3d-from-360-photos-using-ai-and-computer-vision/
- Geo Week: smartphone 3D capture + smart measurement — https://www.geoweeknews.com/articles/matterport-announces-3d-capture-and-smart-measurement-for-smartphones-using-ai/
- Matterport Assisted Alignment — https://support.matterport.com/hc/en-us/articles/115007423487-Assisted-Alignment
- Matterport Capture for iOS — https://support.matterport.com/hc/en-us/articles/1500004898402-Matterport-Capture-for-iOS
- Matterport 360°→3D conversion — https://support.matterport.com/hc/en-us/articles/360026831293-How-to-Convert-a-360-View-to-a-3D-Scan-
- Scan2CAD: Matterport Capture basics — https://www.scan2cad.com/blog/cad/matterport-capture-basics/
- Panomity open-source Matterport-style pipeline — https://panomity.com/virtual-reality-blog/matterport-alternative-3d-tours-360-photos/
- Depth Anything V2 — https://github.com/DepthAnything/Depth-Anything-V2
- PanoFormer (equirect depth) — https://arxiv.org/pdf/2203.09283
- HoHoNet (360 indoor understanding) — https://arxiv.org/pdf/2011.11498
- ARKit — https://developer.apple.com/documentation/arkit · ARCore — https://developers.google.com/ar
- ARCore supported devices — https://developers.google.com/ar/devices
- OpenCV stitching — https://docs.opencv.org/4.x/d1/d46/group__stitching.html
- three.js equirect panorama example — https://threejs.org/examples/#webgl_panorama_equirectangular
- glTF — https://registry.khronos.org/glTF/ · Draco — https://github.com/google/draco
- Open3D TSDF integration — http://www.open3d.org/docs/latest/tutorial/pipelines/rgbd_integration.html
- COLMAP — https://colmap.github.io/
- Supabase pricing — https://supabase.com/pricing · Vercel pricing — https://vercel.com/pricing
- pgTAP — https://pgtap.org/
