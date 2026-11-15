import pathlib,re,json
p=pathlib.Path(__file__).parent
source=(p/"src/index.tsx").read_text()
scenes=re.findall(r"\{id:'([^']+)',duration:([\d.]+)\}",source)
starts={};cursor=0
for i,(name,duration) in enumerate(scenes):
    if i:cursor-=8
    starts[name]=cursor/30;cursor+=round(float(duration)*30)
captions=json.loads((p/"captions.json").read_text());cues=[]
for name,segments in captions.items():
    if name=="research-end":continue
    offsets={"guidance":starts["kiosk"]+12.3,"tour-intro":starts["crm"]+7.3,"tour-closure":starts["crm"]+16.25,"tour-mobile":starts["crm"]+18.65}
    base=offsets[name] if name in offsets else starts[name]+.1
    for segment in segments:
        if name=="crm" and segment["start"]>=6.1:continue
        cues.append((base+segment["start"],base+segment["end"],segment["text"]))
for name,scene in [("kioskLines","kiosk"),("doctorLines","consultation")]:
    part=source.split("const "+name+"=[",1)[1].split("];",1)[0]
    for line in part.splitlines():
        times=re.search(r"a:([\d.]+),b:([\d.]+)",line)
        text=re.search(r"text:'([^']+)'",line)
        who=re.search(r"who:'([^']+)'",line)
        translation=re.search(r"translation:'([^']+)'",line)
        if not times or not text:continue
        caption=who[1]+": "+text[1]
        if translation and "· FINNISH" in who[1]:caption+="\n"+translation[1]
        cues.append((starts[scene]+float(times[1]),starts[scene]+float(times[2]),caption))
def stamp(s):
    ms=round(s*1000);return f"{ms//3600000:02}:{ms//60000%60:02}:{ms//1000%60:02},{ms%1000:03}"
out="\n\n".join(f"{i+1}\n{stamp(a)} --> {stamp(b)}\n{text}" for i,(a,b,text) in enumerate(sorted(cues)))+"\n"
(p/"EdgeCare-Trailer-V4.srt").write_text(out)
(p/"timeline.json").write_text(json.dumps({"starts":starts,"duration":cursor/30},indent=2))
print("Created",len(cues),"timed subtitle cues.")
