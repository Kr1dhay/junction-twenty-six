import json,pathlib,subprocess
p=pathlib.Path(__file__).resolve().parent/"out"
source=p/"EdgeCare-Trailer-V4-render.mp4"
final=p/"EdgeCare-Trailer-V4-1080p.mp4"
probe=subprocess.run(["ffmpeg","-hide_banner","-i",str(source),"-af","loudnorm=I=-16:TP=-1.5:LRA=9:print_format=json","-vn","-f","null","-"],capture_output=True,text=True,check=True)
stats=json.JSONDecoder().raw_decode(probe.stderr[probe.stderr.rfind("{"):])[0]
f=f"loudnorm=I=-16:TP=-1.5:LRA=9:measured_I={stats['input_i']}:measured_TP={stats['input_tp']}:measured_LRA={stats['input_lra']}:measured_thresh={stats['input_thresh']}:offset={stats['target_offset']}:linear=true"
subprocess.run(["ffmpeg","-v","error","-y","-i",str(source),"-c:v","copy","-af",f,"-c:a","aac","-b:a","256k","-ar","48000","-movflags","+faststart",str(final)],check=True)
info=json.loads(subprocess.check_output(["ffprobe","-v","error","-show_streams","-show_format","-of","json",str(final)]))
v=next(s for s in info["streams"] if s["codec_type"]=="video");a=next(s for s in info["streams"] if s["codec_type"]=="audio")
assert (v["width"],v["height"],v["r_frame_rate"],v["codec_name"],a["codec_name"])==(1920,1080,"30/1","h264","aac")
duration=float(info["format"]["duration"])
assert 115<duration<=125,f"Runtime {duration} exceeds the agreed 2:05 cap or is unexpectedly short"
decode=subprocess.run(["ffmpeg","-v","error","-i",str(final),"-f","null","-"],capture_output=True,text=True,check=True)
assert not decode.stderr,decode.stderr
levels=subprocess.run(["ffmpeg","-hide_banner","-i",str(final),"-af","ebur128=peak=true","-vn","-f","null","-"],capture_output=True,text=True,check=True)
summary=levels.stderr[levels.stderr.rfind("Summary:"):].split("[out#")[0].strip()
report={"video":final.name,"resolution":"1920x1080","fps":30,"duration_seconds":duration,"hard_cap_seconds":125,"size_mb":round(final.stat().st_size/1024/1024,1),"video_codec":"h264","audio_codec":"aac","full_decode":"passed","audio_summary":summary}
(p/"verification.json").write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
