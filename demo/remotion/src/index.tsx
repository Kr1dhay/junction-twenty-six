import { AbsoluteFill, Composition, Html5Audio, OffthreadVideo, Sequence, interpolate, registerRoot, staticFile, useCurrentFrame } from "remotion";

export type StoryProps = { voiceover?: string; kioskFootage?: string; verificationFootage?: string; patientFootage?: string };
const color = { ink: "#3c4242", brand: "#830051", accent: "#d0006f", surface: "#f8f8f8", gold: "#f0ab00" };
const fps = 30;
const scenes = [
  { start: 0, seconds: 15, kicker: "THE LAST MILE", title: "Care starts with trust.", body: "An estimated 3,000–6,000 undocumented people live in Finland. Language, information and trust can stand between a person and care.", source: "Source: lsv.fi/en/healthcare-for-undocumented-migrants/", detail: "Anonymous. Multilingual. Offline first." },
  { start: 15, seconds: 20, kicker: "01 / THE KIOSK", title: "A conversation. In your language.", body: "Speak or type. Read a letter on the device. Continue the local flow when the network disappears.", detail: "English   Suomi   Soomaali   العربية   Русский", footage: "kioskFootage" },
  { start: 35, seconds: 15, kicker: "02 / SEAL THE REFERRAL", title: "You are the key.", body: "Draw your signature. Choose four digits, twice. The shared protocol encrypts the template and seals a commitment.", detail: "No account. No recovery channel. Keep your code in mind." },
  { start: 50, seconds: 15, kicker: "03 / THE DOCTOR", title: "A referral. Without an identity.", body: "A clinician sees the summary and recommended next step. The signature and code stay out of the CRM read model.", detail: "Anonymous referral  ·  Clinician review  ·  Live status" },
  { start: 65, seconds: 15, kicker: "04 / ONE-TIME VERIFICATION", title: "Draw. Enter. Verify.", body: "The doctor’s device checks the encrypted template and commitment. The shared registry accepts a single spend.", detail: "Offline verification remains provisional until synchronized.", footage: "verificationFootage" },
  { start: 80, seconds: 10, kicker: "05 / YOUR OWN PHONE", title: "The same care companion. In your pocket.", body: "The patient app shares the kiosk’s flow, with an encrypted referral wallet and a simple hand-off.", detail: "Edge-Care · Junction 2026 · Synthetic demonstration", footage: "patientFootage" },
] as const;

function Scene({ scene, footage }: { scene: typeof scenes[number]; footage?: string }) {
  const frame = useCurrentFrame();
  const opacity = interpolate(frame, [0, 12], [0, 1], { extrapolateRight: "clamp" });
  return <AbsoluteFill style={{ background: color.surface, color: color.ink, fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif", padding: "72px 96px", opacity }}>
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", color: color.brand, fontSize: 24, fontWeight: 600 }}><span>Edge-Care</span><span style={{ fontSize: 16, letterSpacing: 2 }}>{scene.kicker}</span></div>
    <div style={{ display: "flex", alignItems: "center", flex: 1, gap: 64 }}>
      <div style={{ flex: 1 }}><h1 style={{ fontSize: footage ? 64 : 76, lineHeight: 1.08, fontWeight: 600, letterSpacing: -2, margin: "0 0 32px" }}>{scene.title}</h1>
        <p style={{ fontSize: 30, lineHeight: 1.5, maxWidth: 1060 }}>{scene.body}</p>
        <p style={{ marginTop: 40, fontSize: 24, lineHeight: 1.5, color: color.brand }}>{scene.detail}</p>
      </div>
      {footage ? <OffthreadVideo src={staticFile(footage)} muted style={{ height: 700, maxWidth: 620, objectFit: "contain", borderRadius: 24 }} /> : null}
    </div>
    <div style={{ display: "flex", justifyContent: "space-between", gap: 24, fontSize: 17, color: "#636868" }}>
      <span>{"source" in scene ? scene.source : "Demonstration only · guidance is not a diagnosis or guarantee of care"}</span>
      <span>{footage ? "Device recording" : "Illustrated storyboard · replace with recorded app footage"}</span>
    </div>
  </AbsoluteFill>;
}

function Story(props: StoryProps) {
  return <AbsoluteFill>
    {scenes.map(scene => <Sequence key={scene.start} from={scene.start * fps} durationInFrames={scene.seconds * fps}>
      <Scene scene={scene} footage={"footage" in scene ? props[scene.footage] : undefined} />
    </Sequence>)}
    {props.voiceover ? <Html5Audio src={staticFile(props.voiceover)} /> : null}
  </AbsoluteFill>;
}
function Root() { return <Composition id="EdgeCare" component={Story} durationInFrames={90 * fps} fps={fps} width={1920} height={1080} defaultProps={{} satisfies StoryProps} />; }
registerRoot(Root);
