import json,os,urllib.request,urllib.error,time,pathlib,subprocess
p=pathlib.Path(__file__).parent
items=[
("opening","Across Finland, language, anxiety, distance and missing paperwork can put care out of reach, so we're bringing the first conversation into familiar places, closer to home."),
("welcome","Edge Care is a physical iPad kiosk for libraries and community centres. Walk up and talk to Edi, powered by Gemini."),
("research","An optional voice sample supports clinician review. Never a cancer diagnosis."),
("research-end","For clinician review. Never a cancer diagnosis."),
("handoff","Scan a letter. Add a skin photo. Leave with clear guidance. A signature and four digits protect the handoff, designed for single use with Solana."),
("doctor","At the doctor, ElevenLabs turns two languages into one conversation."),
("crm","Referrals, visits and follow-up come together. Public Finnish data reveals access gaps. Test where another doctor, interpreter or mobile clinic could help."),
("closing","Edge Care. An easier first step. A clearer path to care.")
 ,("guidance","Edi summarises your symptoms and recommends the next step. Here, the referral is high priority: speak to a medical professional as soon as possible.")
 ,("tour-intro","In the digital twin, explore how far people travel, where doctor capacity is stretched, and who may need an interpreter.")
 ,("tour-closure","Test a clinic closure.")
 ,("tour-mobile","Then simulate a mobile clinic, and compare where it could help most.")
]
results=[]
for name,text in items:
 dest=p/"public"/("n-"+name+".mp3")
 if not dest.exists():
  req=urllib.request.Request("https://api.elevenlabs.io/v1/text-to-speech/O4fnkotIypvedJqBp4yb?output_format=mp3_44100_128",data=json.dumps({"text":text,"model_id":"eleven_multilingual_v2","voice_settings":{"stability":.5,"similarity_boost":.75,"style":.15,"speed":1.12}}).encode(),headers={"xi-api-key":os.environ["ELEVENLABS_API_KEY"],"Content-Type":"application/json"})
  for attempt in range(4):
   try:
    with urllib.request.urlopen(req,timeout=120) as r:dest.write_bytes(r.read())
    break
   except urllib.error.HTTPError as e:
    if attempt==3:raise RuntimeError(str(e.code)+e.read().decode()[:400])
    time.sleep(3)
 dur=float(subprocess.check_output(["ffprobe","-v","error","-show_entries","format=duration","-of","default=nw=1:nk=1",str(dest)]))
 results.append({"id":name,"text":text,"duration":dur})
 print(name,dur,flush=True)
(p/"narration.json").write_text(json.dumps(results,indent=2))
