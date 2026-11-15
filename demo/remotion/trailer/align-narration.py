import pathlib,json,os,urllib.request,uuid,concurrent.futures
p=pathlib.Path(__file__).parent
def align(item):
    dest=p/"research"/("alignment-"+item["id"]+".json")
    if dest.exists():return json.loads(dest.read_text())
    boundary=uuid.uuid4().hex
    body=(f"--{boundary}\r\nContent-Disposition: form-data; name=\"text\"\r\n\r\n{item['text']}\r\n"
          f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"narration.mp3\"\r\nContent-Type: audio/mpeg\r\n\r\n").encode()
    body+=(p/"public"/("n-"+item["id"]+".mp3")).read_bytes()+f"\r\n--{boundary}--\r\n".encode()
    req=urllib.request.Request("https://api.elevenlabs.io/v1/forced-alignment",data=body,headers={"xi-api-key":os.environ["ELEVENLABS_API_KEY"],"Content-Type":"multipart/form-data; boundary="+boundary})
    with urllib.request.urlopen(req,timeout=120) as r:result=json.load(r)
    dest.write_text(json.dumps(result,indent=2))
    print("Aligned",item["id"],flush=True)
    return result
items=json.loads((p/"narration.json").read_text())
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results=list(pool.map(align,items))
captions={}
for item,result in zip(items,results):
    groups=[];words=[];start=None;end=None
    for word in result["words"]:
        text=word["text"].strip()
        if not text:continue
        if start is None:start=word["start"]
        words.append(text);end=word["end"]
        if text.rstrip().endswith((".", "?", "!")) or len(" ".join(words))>110:
            groups.append({"start":start,"end":end,"text":" ".join(words)})
            words=[];start=None
    if words:groups.append({"start":start,"end":end,"text":" ".join(words)})
    if item["id"]=="opening":
        spoken=[word for word in result["words"] if word["text"].strip()]
        groups=[{"start":part[0]["start"],"end":part[-1]["end"],"text":" ".join(word["text"].strip() for word in part)}
                for part in [spoken[:8],spoken[8:14],spoken[14:]]]
    captions[item["id"]]=groups
(p/"captions.json").write_text(json.dumps(captions,indent=2,ensure_ascii=False))
print(json.dumps(captions["opening"],indent=2))
