# Wispr Flow dictation pill — extracted implementation

| Item | Exact value / behavior | Evidence |
|---|---|---|
| Bundle inspected | Installed version **1.6.1074**; static inspection of a copied `app.asar` | E01 |
| Target component | Status renderer `q_` inside `U_`; normal dictation, bottom dock. The capsule with cancel and finish glyphs is `ACTIVE_POPO`; PTT uses the same bars. | E02, E53, E57, E58 |
| Bar count | **10**; generic component default, not an estimate from appearance | E02 |
| Bar width / gap | **2 CSS px / 2 CSS px**. Width is `--waveform-bar-width` with a 2 px fallback; no assignment overriding that property was found in the extracted renderer sources. | E06, E13 |
| Bar substrate / radius | **2 px minimum layout height**, **0.5 px radius**, centered transform origin. No explicit normal-dictation maximum height declaration. Scaling affects the rendered radius along the growth axis too. | E06, E07 |
| Actual silent heights while animation is enabled | Unit audio-scale floor, multiplied by the fixed profile and animated multiplier; **not ten equal 2 px dots**. Derived minimum is **1.15625 px** at an outer bar; the center pair has profile **191/192**. | E04, E34, E08, E06 |
| Maximum rendered height | Derived mathematical upper bound **14.921875 px** for the center pair: `2 × 5 × (191/192) × 1.5`. The height before the profile is at most **15 px**. These are formula bounds, not CSS literals or a measured runtime peak; quantization generally prevents a zero-initialized smoother reaching full scale. | E06, E33, E34, E04, E08, E25, E35 |
| Fixed per-bar profile | `max(0, 1 - abs((count-1)/2 - index)^2 / 48)` for default coefficient **1**. No randomness or resampling. The alternate linear branch applies only when coefficient is **≥2**. | E02, E04 |
| Fixed phase delays | Seconds: **[0, 0.1, 0.2, 0.3, 0.4, -0.5, -0.4, -0.3, -0.2, -0.1]**. Construct signed indices with split `ceil(count/2)`; multiply by **0.1 s**. Positive delays wait initially; negative delays start partway through the cycle. | E03, E05 |
| Breathing multiplier | Repeated **1 s** CSS animation; keyframes `(fraction, multiplier)` = **[(0,1), (0.2,1.2), (0.4,1.5), (0.8,1.1), (0.9,1.3), (1,1)]**, **ease-in-out within each segment** | E07, E08, E09, E10, E11 |
| Level source | **RMS → dBFS** in the **hub renderer**, after worklet samples arrive: `20*log10(sqrt(mean(sample²)) + 1e-10)`. It is not peak amplitude. The worklet buffers samples; main process normalizes the supplied dB value. | E20, E23, E21, E22, E17, E24, E26, E27 |
| Capture cadence | Worklet chunks **640 samples**, nominal quantum **128 samples**, requested AudioContext rate **16,000 Hz**; WAV packet duration field **40 ms**. Thus normally one full chunk per **40 ms** of captured audio; stop can flush a partial chunk. | E16, E17, E18, E19, E64 |
| Main-process normalization | Adaptive floor initialized to **0 dB**; when a lower dB value arrives, floor becomes `max(-60, db)`. Level is `clamp((db-floor)/20, 0, 1)`. This is linear in dB above the floor, with **20 dB span** and **-60 dB floor bound**, not linear in sample amplitude. | E25, E27 |
| Level delivery | Arithmetic mean of normalized **WAV** levels collected in each **150 ms** interval; empty batches send nothing. Channel **`status:audioLevel`**, target status window. No fixed batch size: sample arrival and timer phase determine it. | E28, E29, E30, E31, E32 |
| Renderer gain / clamp | Normal dictation gain **5**; `audioScale = max(1, 5*smoothedLevel)` | E33, E34 |
| Renderer smoothing | Each **requestAnimationFrame**: `smooth = floor(100*(0.85*smooth + (1-0.85)*target))/100`. Same coefficient for rising/falling levels; downward hundredth quantization. Initial smooth and target are zero. No separate attack/decay constants in this branch. | E35, E36, E63 |
| Smoothing frame rate | Browser rAF cadence, **not a fixed timer**; no explicit normal-dictation FPS cap. The separate shared **20 Hz** ticker is selected for meeting chrome, not this pill. | E33, E35, E38 |
| CSS smoothing transition | No bar height/transform transition in the bar module. The **waveform container and capsule layout** have `transition: all 0.1s cubic-bezier(0.05, 0.6, 0.4, 0.95)`. This is distinct from bar-level interpolation and the per-segment breathing easing. | E06, E07, E12, E55 |
| Resting / ready | Resting waveform container **opacity 0**; resting bottom capsule **40×8 px**, radius **6 px**. Ready/context-menu replaces bars with a **16 px microphone icon**. Active but silent can continue breathing while waveform animation remains enabled. | E42, E59, E60, E43, E41 |
| Normal active capsule | Bottom POPO **102.5×30 px**, PTT **73×30 px**, declared capsule radius **22.5 px**, **1 px** border. Cancel/finish glyphs use **12 px** size and **3** stroke width. Waveform box has declared **18 px** height and **8 px vertical / 4 px horizontal** padding; preserve the declarations rather than interpreting 18 px as a bar clamp. | E52, E51, E53, E54, E56, E15 |
| Processing | Clear level/animation state, keep waveform node, add radial spinner: **8 spokes**, **45°** apart, translated **6 px** from center, **16×16 px** container; spokes **2×5 px**, radius **1 px**. Fade cycle **1.1 s linear**, delay `-0.1375*(7-index)` seconds, alpha **0.88→0.15**. Fixed spokes fade; they do not rotate continuously. | E44, E45, E37, E46, E47, E48, E49, E50 |
| Motion / orientation | Stable indexed bar nodes; centered `scaleY` at bottom. Side docking lays bars vertically and uses centered `scaleX`; **2 px** transverse thickness. There is no shifting sample history, horizontal translation, or scrolling mechanism in this visualizer. | E04, E06, E14, E61, E62 |

## Mapping in pseudocode

This reproduces **normal dictation**, including the upstream normalization. Use CSS pixels as logical drawing units. If the Swift audio API already supplies a normalized level, start at `onStatusAudioLevel`; otherwise calculate dB from Float32 microphone samples. References for constants and formulas are in the table above.

```text
// Persistent main-process state; the scaler is created at module scope.
noiseFloorDb = 0
pendingLevels = []

onMicrophoneChunk(samples):                 // normally 640 samples at 16 kHz
    rms = sqrt(sum(sample * sample) / samples.count)
    db = 20 * log10(rms + 1e-10)           // hub renderer, before PCM conversion
    if db < noiseFloorDb:
        noiseFloorDb = max(-60, db)
    level = clamp((db - noiseFloorDb) / 20, 0, 1)
    pendingLevels.append(level)             // main process: WAV packets only

every150Milliseconds():                    // timer starts when first WAV level arrives
    if pendingLevels.isEmpty: return        // no automatic zero for an empty batch
    sendStatusAudioLevel(mean(pendingLevels))
    pendingLevels.removeAll()

// Renderer hook state. Separate from the main-process adaptive floor.
target = 0
smoothed = 0
showWaveformAnimation = false               // controlled by mic/state events
animationStartTime = undefined             // time the CSS animation class starts
keyframes = [(0,1), (.2,1.2), (.4,1.5), (.8,1.1), (.9,1.3), (1,1)]

onStatusAudioLevel(level):
    if currentStateAcceptsAudioLevels:
        target = level                     // hold until next event or explicit clear
        if level > 0: scheduleRAF()

clearWaveform():
    target = 0
    showWaveformAnimation = false           // caller clears this independently of hook
    scheduleRAF()

onAnimationFrame():
    if documentIsHidden: stopRAF(); return
    effectiveTarget = paused ? 0 : target
    smoothed = floor(100 * (.85*smoothed + (1-.85)*effectiveTarget)) / 100
    if waveformIsVisible:
        audioScale = max(1, 5*smoothed)     // update inherited --audio-scale
    if effectiveTarget != 0 or smoothed != 0: scheduleRAF()
    else: stopRAF()

heightsAtPresentationTime(now):             // CSS presentation timeline, independent of IPC
    audioScale = lastWrittenAudioScaleOr(1)
    return indices(0..<10).map(index ->
        if not showWaveformAnimation:
            return 2                       // no scaleY class: substrate height
        profile = max(0, 1 - pow(abs((10-1)/2 - index), 2)/48)
        signedIndex = index < ceil(10/2) ? index : index-10
        elapsed = now - animationStartTime - .1*signedIndex
        if elapsed < 0:
            multiplier = 1                 // positive delay; no animation fill mode
        else:
            phase = fractionalPart(elapsed / 1.0)
            (t0,v0),(t1,v1) = bracketingKeyframes(keyframes, phase)
            progress = (phase-t0)/(t1-t0)
            multiplier = v0 + (v1-v0)*cssEaseInOut(progress)
        return 2 * audioScale * profile * multiplier
    )
```

`cssEaseInOut` means the standard **CSS named easing**, applied separately between adjacent keyframes, not a sine wave or a linear lookup. Use fractional heights; draw each bar around a fixed center, preserving fixed width and gap. Positive phase delays use the static transform before their first cycle. The profile is applied only when the animation class is present. Unanimated active bars remain the substrate height; resting bars are hidden by the container.

The hundredth truncation is part of the implementation. It can stop rising below the exact target; do not replace it with rounding or a time-adjusted exponential if exact behavior is wanted. The hook does not decay solely because an IPC event stops arriving: it retains the last target. Zero-valued audio chunks or an explicit clear drive decay. The adaptive main-process floor is a different state variable, bounded below and updated only by lower inputs; it is not a continuously smoothed noise estimate.

The full envelope combines the common audio scale, a static parabolic profile, and staggered periodic motion. Only the profile is symmetric; the staggered phases make neighboring bars move differently. The waveform is a level display, not the scrolling waveform of recorded audio.

For clarity about nearby code: **meeting chrome** selects gain **2**, the **20 Hz** shared ticker, time-adjusted retention `pow(.85, dt/(1000/60))`, a rate limit of **1.6 level units/s**, `dt` clamped to **1…200 ms**, and hundredth truncation (E33, E38, E39, E40). Its waveform uses different count/coefficient overrides and clipping. The nearby smoothstep function used for its keyframe lookup is not the normal dictation pill's CSS easing. The separate instruct mini-waveform also has different profile/gain data. Neither implementation has been substituted into the function above.

## Evidence

Paths below are relative to the **copied archive's extracted root**. Offsets are zero-based Unicode character offsets into each decoded UTF-8 file, not line numbers or byte offsets. Every quoted fragment is an exact contiguous substring of at most 300 characters. Selector-list tails share their declarations with earlier selectors in the same rule; the state aliases identify the active POPO/PTT selectors.

Copied archive SHA-256: `4e8761a527af2e79bea5089d8330303f652a193fed65265f66028b7881ba5577`.

- **E01 — Installed bundle version**. `package.json`, character 59:

  `"version": "1.6.1074"`

- **E02 — Dictation component defaults**. `.webpack/renderer/status/index.js`, character 323603:

  `barCount:l=10,bulgeCoefficient:_=1`

- **E03 — Fixed signed delay-index array**. `.webpack/renderer/status/index.js`, character 323716:

  `p=Math.ceil(l/2),m=(0,b.useMemo)(()=>Array.from({length:l},(e,t)=>t<p?t:t-l),[l,p])`

- **E04 — Parabolic dictation profile; linear branch for other coefficients**. `.webpack/renderer/status/index.js`, character 324496:

  `const u=(l-1)/2;return Array(l).fill(0).map((l,p)=>{const h=Math.abs(u-p),g=_>=2?Math.max(0,1-h*(_/48)):Math.max(0,1-Math.pow(h,2)*(_/48));`

- **E05 — Per-bar profile and phase assignment**. `.webpack/renderer/status/index.js`, character 324881:

  `style:{"--bar-height-scale":g,animationDelay:.1*m[p]+"s"}`

- **E06 — Base bars: dimensions, color and centered transform**. `.webpack/renderer/status/index.js`, character 610834:

  `.B4XZ4GNPPaVGa4a2IAeg{width:var(--waveform-bar-width, 2px);min-height:var(--waveform-bar-width, 2px);background:hsla(0,0%,100%,.4);border-radius:.5px;transform-origin:center;will-change:transform}`

- **E07 — Dictation transform and animation**. `.webpack/renderer/status/index.js`, character 611561:

  `.B4XZ4GNPPaVGa4a2IAeg.B21adkkiHoQbTgH2Lbo0{transform:scaleY(calc(var(--audio-scale, 1) * var(--bar-height-scale, 1)));animation:__sN13fyFt35sDlqeeLV 1s infinite ease-in-out}`

- **E08 — Keyframe times and multipliers; mirrored by CSS below**. `.webpack/renderer/status/index.js`, character 323401:

  `H_=[[0,1],[.2,1.2],[.4,1.5],[.8,1.1],[.9,1.3],[1,1]]`

- **E09 — Dictation CSS keyframes, first segment**. `.webpack/renderer/status/index.js`, character 613244:

  `0%{transform:scaleY(calc(var(--audio-scale, 1) * var(--bar-height-scale, 1) * 1))}20%{transform:scaleY(calc(var(--audio-scale, 1) * var(--bar-height-scale, 1) * 1.2))}`

- **E10 — Dictation CSS keyframes, middle segments**. `.webpack/renderer/status/index.js`, character 613411:

  `40%{transform:scaleY(calc(var(--audio-scale, 1) * var(--bar-height-scale, 1) * 1.5))}80%{transform:scaleY(calc(var(--audio-scale, 1) * var(--bar-height-scale, 1) * 1.1))}`

- **E11 — Dictation CSS keyframes, final segments**. `.webpack/renderer/status/index.js`, character 613581:

  `90%{transform:scaleY(calc(var(--audio-scale, 1) * var(--bar-height-scale, 1) * 1.3))}100%{transform:scaleY(calc(var(--audio-scale, 1) * var(--bar-height-scale, 1) * 1))}`

- **E12 — Waveform container: alignment and layout transition**. `.webpack/renderer/status/index.js`, character 687997:

  `.T1nupWfdASRx5xjBqq0A{display:inline-flex;flex-direction:column;justify-content:center;align-items:center;flex-shrink:0;transition:all .1s cubic-bezier(0.05, 0.6, 0.4, 0.95)}`

- **E13 — End of shared active waveform selector list; same declarations cover active PTT/POPO**. `.webpack/renderer/status/index.js`, character 688572:

  `.T1nupWfdASRx5xjBqq0A.wfNrF2LT_m2_bG2w8aIJ{width:18px;padding:4px 8px;gap:2px}`

- **E14 — Bottom-docked horizontal bar layout**. `.webpack/renderer/status/index.js`, character 696510:

  `[data-bar-position="bottom"] .T1nupWfdASRx5xjBqq0A{flex-direction:row}`

- **E15 — End of shared bottom active waveform selector list**. `.webpack/renderer/status/index.js`, character 697223:

  `.T1nupWfdASRx5xjBqq0A.wfNrF2LT_m2_bG2w8aIJ{width:auto;height:18px;padding:8px 4px}`

- **E16 — Worklet chunk size and nominal render quantum**. `.webpack/renderer/dist/recorderWorklet.js`, character 95:

  `this.chunkSize=640,this.numInputStreams=e.numberOfInputs,this.renderQuantumSize=128`

- **E17 — Worklet sends sample arrays, not a level**. `.webpack/renderer/dist/recorderWorklet.js`, character 1063:

  `sendDataAsKeyValue(e){let t={};for(let s=0;s<this.numInputStreams;s++)t[s]=this.buffer[s].slice(0,e),this.bufferIndex[s]=0;this.port.postMessage(t)}`

- **E18 — WAV packet duration and audio sample rate**. `.webpack/renderer/hub/index.js`, character 648473:

  `J_=40,X_=16e3`

- **E19 — Dictation AudioContext sample rate**. `.webpack/renderer/hub/index.js`, character 727433:

  `const t=performance.now(),n=new AudioContext({sampleRate:X_,latencyHint:Y_})`

- **E20 — Hub renderer RMS to dBFS**. `.webpack/renderer/hub/index.js`, character 203706:

  `const b=e=>{const t=Math.sqrt(e.reduce((e,t)=>e+t*t,0)/e.length);return 20*Math.log10(t+1e-10)}`

- **E21 — Worklet first input supplies Float32 samples**. `.webpack/renderer/hub/index.js`, character 735139:

  `const n=e.data[0],a=af(n)`

- **E22 — RMS level accompanies WAV packet IPC**. `.webpack/renderer/hub/index.js`, character 735888:

  `const r=(0,X.yM)(n),i={packet:a.buffer,index:lf.wavChunkIndex,volume:r,duration:J_,encoding:"wav",transcriptionEntityUuid:lf.activeChunkUuid};(0,Oe.$)(C.kH.AudioChunk,!1,i)`

- **E23 — RMS utility export alias**. `.webpack/renderer/hub/index.js`, character 201849:

  `yM:()=>b`

- **E24 — Dictation main process imports audio scaling utility**. `.webpack/main/index.js`, character 4163039:

  `j=n(59719)`

- **E25 — Adaptive floor, span and clamps**. `.webpack/main/index.js`, character 2918451:

  `_=-60,E=(e=_,t=20)=>{let n=0;return{scale:r=>(r<n&&(n=Math.max(e,r)),Math.max(0,Math.min(1,(r-n)/t))),reset:(e=0)=>{n=e},getCurrentFloor:()=>n}}`

- **E26 — Adaptive scaler export alias**. `.webpack/main/index.js`, character 2915909:

  `Jr:()=>E`

- **E27 — Dictation scaler uses default parameters**. `.webpack/main/index.js`, character 4205632:

  `En=(0,j.Jr)()`

- **E28 — Per-WAV normalization, arithmetic batch mean and empty-batch skip**. `.webpack/main/index.js`, character 4231810:

  `"wav"===a){const e=En.scale(r);((e,t)=>{Rn.push(t),Bn||(Bn=setInterval(()=>{(e=>{if(0===Rn.length)return;const t=Rn.reduce((e,t)=>e+t,0)/Rn.length;`

- **E29 — Batch mean sent on status AudioLevel channel**. `.webpack/main/index.js`, character 4231960:

  `(0,y.Bn)(e,m.LF.AudioLevel,t)`

- **E30 — Clear batch and 150 ms IPC interval**. `.webpack/main/index.js`, character 4232231:

  `Rn=[]})(e)},150))})((0,_t.nB)(),e)`

- **E31 — IPC channel string**. `.webpack/main/index.js`, character 2681417:

  `e.AudioLevel="status:audioLevel"`

- **E32 — nB exported helper selects the status window**. `.webpack/main/index.js`, character 4295143:

  `he=()=>ie.RA.statusWindow||(o().warn("[StateManager] Bubble window is not available - statusWindow is null"),null)`

- **E33 — Normal dictation gain and non-ticker mode; other chrome differs**. `.webpack/renderer/status/index.js`, character 407985:

  `k=Vl({gain:i?2:5,paused:n||i&&o===Tt.R0.Idle,accept:g,floor:!(a&&r&&!i),ticker:i})`

- **E34 — Output audio scale has a unit floor by default**. `.webpack/renderer/status/index.js`, character 308348:

  `const a=o.current*e,r=String(i.current?Math.max(1,a):a)`

- **E35 — Normal pill smoothing per rAF and hundredth truncation**. `.webpack/renderer/status/index.js`, character 309201:

  `const t=a.current?0:s.current,o=function(e,t){const o=.85*e+t*(1-.85);return Math.floor(100*o)/100}(l.current,t);l.current=o,p(o),_.current=0!==t||0!==o?requestAnimationFrame(e):null`

- **E36 — Audio level becomes the target; accepted positive levels schedule animation**. `.webpack/renderer/status/index.js`, character 309428:

  `Kr(wt.LF.AudioLevel,e=>{const t=n.current;t&&!t(e)||(s.current=e,e>0&&g())})`

- **E37 — Explicit clear sets target to zero**. `.webpack/renderer/status/index.js`, character 309925:

  `e.clear=()=>{s.current=0,g()}`

- **E38 — Shared ticker nominal frequency, used by meeting chrome**. `.webpack/renderer/status/index.js`, character 306898:

  `let Ml=20;const Rl=new Set`

- **E39 — Ticker-only time-adjusted, rate-limited smoothing**. `.webpack/renderer/status/index.js`, character 308695:

  `const n=Math.min(Math.max(o,1),200),i=Math.pow(.85,n/Ul),a=e*i+t*(1-i),r=n/1e3*1.6,s=Math.min(r,Math.max(-r,a-e));return Math.floor(100*(e+s))/100`

- **E40 — Ticker-only reference frame interval**. `.webpack/renderer/status/index.js`, character 307821:

  `Ul=1e3/60`

- **E41 — Mic-active event toggles showWaveformAnimation**. `.webpack/renderer/status/index.js`, character 407815:

  `(Ar.includes(e)||e===Bt.fw.ACTIVE_POPO||t)&&(u(o),l(o))`

- **E42 — Resting waveform container is invisible**. `.webpack/renderer/status/index.js`, character 688171:

  `.T1nupWfdASRx5xjBqq0A.V3tpzMBfPm7zOuSMWhXG{width:5px;height:13px;padding:1px 2px;gap:.5px;opacity:0}`

- **E43 — Ready state replaces bars with a microphone icon**. `.webpack/renderer/status/index.js`, character 325425:

  `case Bt.fw.READY:case Bt.fw.CONTEXT_MENU:return(0,j.jsx)("div",{className:(0,Xe.A)(xr.waveform,xr.micIcon,Fr[e]),children:(0,j.jsx)(Re,{size:16})})`

- **E44 — Dictation processing retains waveform node and adds spinner**. `.webpack/renderer/status/index.js`, character 325573:

  `case Bt.fw.PROCESSING:return(0,j.jsxs)(j.Fragment,{children:[c,(0,j.jsx)(l_,{isCommandMode:t,isInstructMode:o})]})`

- **E45 — Processing clears microphone/level waveform state**. `.webpack/renderer/status/index.js`, character 410385:

  `re.current=Date.now(),F.m.info("[Status Indicator] Processing started"),o&&P(o),bt(),gt()`

- **E46 — Spinner spoke count**. `.webpack/renderer/status/index.js`, character 312897:

  `children:Array(8).fill(0).map`

- **E47 — Spinner spoke angle, radius and negative delay**. `.webpack/renderer/status/index.js`, character 313070:

  ``style:{transform:`rotate(${45*i}deg) translate(0, -6px)`,animationDelay:.1375*-(7-i)+"s"}``

- **E48 — Spinner container size**. `.webpack/renderer/status/index.js`, character 579744:

  `.PY9RDsGuuffXfDWW470I{position:relative;width:16px;height:16px;display:flex;justify-content:center;align-items:center}`

- **E49 — Spinner spoke size and fade animation**. `.webpack/renderer/status/index.js`, character 579862:

  `.v1rh_RmN72v_1fWzMpWm{position:absolute;width:2px;height:5px;border-radius:1px;background:rgba(163,148,199,.3);transform-origin:center center;animation:kxbqeEzp1dX2z__F7jbM 1.1s linear infinite}`

- **E50 — Spinner alpha fades in place**. `.webpack/renderer/status/index.js`, character 580590:

  `@keyframes kxbqeEzp1dX2z__F7jbM{0%{background:rgba(163,148,199,.88)}100%{background:rgba(163,148,199,.15)}}`

- **E51 — Normal bottom PTT capsule**. `.webpack/renderer/status/index.js`, character 695375:

  `[data-bar-position="bottom"] .PPLpv65KBLnEVrLH7wgx.IBQOd10y7kZIVbun3nmQ{width:73px;height:30px}`

- **E52 — Normal bottom POPO capsule with cancel/stop icons**. `.webpack/renderer/status/index.js`, character 695565:

  `[data-bar-position="bottom"] .PPLpv65KBLnEVrLH7wgx.Jw8oNRpJzztq5vwQze1c{width:102.5px;height:30px}`

- **E53 — Capsule state selector names**. `.webpack/renderer/status/index.js`, character 698147:

  `processing:"otcI0kYbKO7iTPd05iKZ",activePopo:"Jw8oNRpJzztq5vwQze1c",activePtt:"IBQOd10y7kZIVbun3nmQ"`

- **E54 — Tail of shared capsule selector list (also includes active POPO)**. `.webpack/renderer/status/index.js`, character 675912:

  `.PPLpv65KBLnEVrLH7wgx.IBQOd10y7kZIVbun3nmQ,.PPLpv65KBLnEVrLH7wgx.CUVB3frdYxV_AaSy2bi7{background:var(--shade-black);border-radius:22.5px;border:1px solid var(--vast-900)}`

- **E55 — Capsule layout transition**. `.webpack/renderer/status/index.js`, character 676183:

  `.PPLpv65KBLnEVrLH7wgx{z-index:1;display:flex;flex-direction:column;justify-content:center;align-items:center;flex-shrink:0;transition:all .1s cubic-bezier(0.05, 0.6, 0.4, 0.95)}`

- **E56 — Shared cancel/finish glyph dimensions**. `.webpack/renderer/status/index.js`, character 260283:

  `const Jr={cancel:B.A,stop:Xr.A},Qr=({name:e})=>{const t=Jr[e];return(0,j.jsx)(t,{size:12,strokeWidth:3})}`

- **E57 — Cancel icon enabled only in POPO state**. `.webpack/renderer/status/index.js`, character 264836:

  `l=e===Bt.fw.ACTIVE_POPO`

- **E58 — Cancel glyph conditional rendering**. `.webpack/renderer/status/index.js`, character 265182:

  `children:l&&(0,j.jsx)(Qr,{name:"cancel"})`

- **E59 — Resting bottom capsule dimensions**. `.webpack/renderer/status/index.js`, character 695165:

  `[data-bar-position="bottom"] .PPLpv65KBLnEVrLH7wgx.V3tpzMBfPm7zOuSMWhXG{width:40px;height:8px}`

- **E60 — Resting capsule radius; base vertical orientation**. `.webpack/renderer/status/index.js`, character 676503:

  `.PPLpv65KBLnEVrLH7wgx.V3tpzMBfPm7zOuSMWhXG{width:8px;height:40px;background-color:rgba(0,0,0,.5);border-radius:6px;border:1px solid hsla(0,0%,100%,.5)}`

- **E61 — Side-docked bars rotate the growth axis**. `.webpack/renderer/status/index.js`, character 611030:

  `[data-bar-position="left"] .B4XZ4GNPPaVGa4a2IAeg,[data-bar-position="right"] .B4XZ4GNPPaVGa4a2IAeg{width:auto;height:2px;min-width:2px;min-height:0}`

- **E62 — Side-docked scaleX animation**. `.webpack/renderer/status/index.js`, character 611319:

  `transform:scaleX(calc(var(--audio-scale, 1) * var(--bar-height-scale, 1)));animation:NDcNjNPcEgGrO_VsakFP 1s infinite ease-in-out`

- **E63 — Target and smoothed level refs start at zero**. `.webpack/renderer/status/index.js`, character 308135:

  `const s=(0,b.useRef)(0),l=(0,b.useRef)(0)`

- **E64 — Stop flushes partial worklet buffer**. `.webpack/renderer/dist/recorderWorklet.js`, character 405:

  `else if("stop"===e.data){this.recording=!1;let e=this.getConsensusBufferIndex();e>0&&this.sendDataAsKeyValue(e)`

## Unknowns

- Actual runtime rAF/CSS presentation cadence and physical-pixel scaling cannot be determined statically. No runtime or visual inspection was performed.
- Runtime preferences, feature flags, microphone gain, device noise, current dock position, and the active instruct/rainbow/meeting variant were not inspected. The fixed capsule dimensions above describe normal dictation; mode-specific CSS can change capsule geometry and whether the output floor applies.
- The maximum height is a proven formula bound under normalized inputs and default parameters, not a runtime measurement. No literal normal-dictation `max-height` or per-bar upper clip is present in the inspected bar module. Ancestor painting/clipping and hardware presentation are not measured.
- The adaptive scaler is initialized at module scope and exposes `reset`; an explicit reset is visible on entering microphone-test mode. Do not assume that every dictation resets the floor. The installed app's current floor is unknown.
- The normal microphone source was traced completely. Alternate BLE/native capture paths and their full acquisition/calibration behavior were not fully traced; this spec does not assert identical upstream dB computation for those paths.

Verification record: DONE for static extraction/specification. Only this repository document was created. The application was not launched, opened, quit, or modified, and its Application Support directory was not read. The prescribed asar extraction reported missing separately unpacked native files because only the archive was copied; the renderer, main-process JavaScript, recorder worklet, and package metadata used here were extracted successfully. All 64 source fragments passed exact substring, Unicode-offset, and length checks. Extracted mathematical expressions passed checks for the adaptive floor, normalized clamps, fixed profile, height bounds, and quantized smoothing. Evidence and profile validators rejected known-bad literals and accepted known-good controls; visual verification remains outside this read-only task. The permitted scratch directory is removed before final delivery.
