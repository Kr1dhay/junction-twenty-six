import React from 'react';
import {AbsoluteFill, Audio, Composition, Img, Sequence, interpolate, registerRoot, spring, staticFile, useCurrentFrame} from 'remotion';
import {HeartPulse, Languages, MapPin, MessageCircle, Library, ArrowRight, ShieldCheck, Mic, Stethoscope} from 'lucide-react';
import narration from '../narration.json';
import captions from '../captions.json';
import finland from '../finland-path.json';
import {TransitionSeries, linearTiming} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';
import {wipe} from '@remotion/transitions/wipe';
import {Circle} from '@remotion/shapes';
import {evolvePath} from '@remotion/paths';
import frames from '../frames.json';

const FPS=30, C={paper:'#faf7f1',ink:'#2d202b',purple:'#830051',pink:'#cf006c',gold:'#f0ab00',muted:'#75636e',dark:'#281b2a'};
const clamp={extrapolateLeft:'clamp' as const,extrapolateRight:'clamp' as const};
const scenes=[
 {id:'opening',duration:11.6},{id:'welcome',duration:7.6},
 {id:'kiosk',duration:22.7},{id:'research',duration:5.2},
 {id:'handoff',duration:10.8},{id:'doctor',duration:4.7},
 {id:'consultation',duration:24.067},{id:'notes',duration:3.2},
 {id:'crm',duration:23},{id:'closing',duration:6},
].map(s=>({...s,frames:Math.round(s.duration*FPS)}));
const transitionFrames=8;
const total=scenes.reduce((a,s)=>a+s.frames,0)-transitionFrames*(scenes.length-1);
const enter=(f:number)=>spring({fps:FPS,frame:f,config:{damping:23,stiffness:130}});
function Brand({dark=false,section=''}:{dark?:boolean,section?:string}){
 return <div style={{position:'absolute',left:60,top:35,display:'flex',alignItems:'center',gap:15,color:dark?'white':C.purple,fontSize:27,fontWeight:700}}>
  <HeartPulse size={30}/>Edge–Care{section&&<span style={{fontWeight:400,color:dark?'#d4c2d2':C.muted,fontSize:22,marginLeft:25}}>{section}</span>}
 </div>;
}
type VideoName=keyof typeof frames;
function Video({name,style,muted=false}:{name:VideoName,style?:React.CSSProperties,muted?:boolean}){
 const frame=useCurrentFrame();
 const index=Math.max(1,Math.min(frames[name],frame+1));
 return <><Img src={staticFile(`frames/${name}/${String(index).padStart(5,'0')}.jpg`)} style={{display:'block',...style}}/>{!muted&&<Audio src={staticFile(name+'.mp4')}/>}</>;
}
function Tablet({name,muted=false}:{name:VideoName,muted?:boolean}){
 return <div style={{position:'absolute',left:45,top:115,width:1270,border:'2px solid #ddd0d8',borderRadius:22,overflow:'hidden',background:'white'}}>
  <Video name={name} muted={muted} style={{width:'100%'}}/>
 </div>;
}
function Caption({text,left=110}:{text:string,left?:number}){
 if(!text)return null;
 return <div style={{position:'absolute',left,right:65,bottom:28,display:'flex',justifyContent:'center'}}>
  <div style={{maxWidth:1620,background:'#251827f2',color:'white',fontSize:31,lineHeight:1.25,padding:'13px 26px',borderRadius:10,textAlign:'center'}}>{text}</div>
 </div>;
}
function Narration({id,delay=0}:{id:string,delay?:number}){
 const f=useCurrentFrame()-Math.round(delay*FPS),n=narration.find(n=>n.id===id)!;
 const text=(captions as Record<string,{start:number,end:number,text:string}[]>)[id]?.find(p=>f/FPS>=p.start&&f/FPS<p.end)?.text||'';
 return <><Sequence from={Math.round(delay*FPS)}><Audio src={staticFile('n-'+id+'.mp3')}/></Sequence><Caption text={text}/></>;
}
function Opening(){
 const f=useCurrentFrame(),reach=interpolate(f,[175,225],[0,1],clamp);
 const journey='M130 710 C390 850 650 590 880 690 S1190 900 1450 715';
 const path=evolvePath(interpolate(f,[10,300],[0,1],clamp),journey);
 return <>
  <Brand section="Finland · the distance to a first conversation"/>
  <div style={{position:'absolute',left:105,top:230,width:800,transform:`translateY(${(1-enter(f))*25}px)`}}>
   <div style={{fontSize:110,lineHeight:1.03,letterSpacing:-5,fontWeight:700}}>Care can feel<br/><span style={{color:C.purple}}>out of reach.</span></div>
   <div style={{fontSize:49,lineHeight:1.2,marginTop:45,opacity:reach,transform:`translateY(${(1-reach)*20}px)`}}>Let’s bring the first<br/>conversation closer.</div>
  </div>
  <svg width="650" height="785" viewBox="-80 -15 650 800" style={{position:'absolute',left:1110,top:105,opacity:.42}}>
   <path d={finland} fill="#e1cad6" stroke="#b987a6" strokeWidth="2"/>
   {[['178','643'],['259','521'],['302','395'],['256','232']].map(([x,y],i)=><g key={i}>
    <circle cx={x} cy={y} r={8+Math.sin(f/19+i)*2} fill={C.purple}/>
    <circle cx={x} cy={y} r={18+Math.sin(f/19+i)*4} fill="none" stroke={C.purple}/>
   </g>)}
  </svg>
  {[
   {x:1000,y:170,n:'646,392',s:'foreign-mother-tongue residents',small:'2025 · language, not Finnish proficiency',delay:12},
   {x:1410,y:355,n:'247,980',s:'sparsely populated rural residents',small:'2025 · Statistics Finland',delay:32},
   {x:970,y:490,n:'≈7%',s:'adults with disabling social anxiety*',small:'Annual clinical estimate · Duodecim',delay:52},
   {x:1390,y:645,n:'3,000–6,000',s:'estimated undocumented people',small:'LSV · estimate, not a census',delay:72},
  ].map(item=><div key={item.n} style={{position:'absolute',left:item.x,top:item.y,opacity:enter(f-item.delay),transform:`translateY(${(1-enter(f-item.delay))*12}px)`}}>
   <div style={{fontSize:51,letterSpacing:-2,fontWeight:700,color:C.purple}}>{item.n}</div>
   <div style={{fontSize:23,marginTop:5}}>{item.s}</div>
   <div style={{fontSize:18,color:C.muted,marginTop:7}}>{item.small}</div>
  </div>)}
  <svg width="1920" height="1080" style={{position:'absolute',inset:0,pointerEvents:'none'}}>
   <path d={journey} fill="none" stroke={C.gold} strokeWidth="5" strokeLinecap="round" {...path}/>
  </svg>
  <div style={{position:'absolute',left:930,top:755,display:'flex',alignItems:'center',gap:20,opacity:reach,transform:`scale(${.85+reach*.15})`}}>
   <div style={{position:'relative',width:90,height:90}}><Circle radius={45} fill={C.gold}/><Library size={43} style={{position:'absolute',left:24,top:22}}/></div>
   <div style={{fontSize:31,fontWeight:650}}>Everyday places.<br/><span style={{fontSize:23,fontWeight:400}}>A more familiar first step.</span></div>
  </div>
  <div style={{position:'absolute',left:105,right:90,bottom:136,fontSize:19,color:C.muted}}>Statistics Finland (2025) · Duodecim (2025) · LSV. *Clinical prevalence estimate, not a Finnish national headcount. Groups overlap.</div>
  <Narration id="opening" delay={.1}/>
 </>;
}
const kioskLines=[
 {a:.42,b:3.81,who:'PATIENT',text:'My voice has been hoarse, and I’ve noticed a small lump in my neck.'},
 {a:5.18,b:8.2,who:'EDI · GEMINI',text:'How long have you been experiencing these symptoms?'},
 {a:8.98,b:11.86,who:'PATIENT',text:'A few weeks, and swallowing has become uncomfortable.'},
];
const doctorLines=[
 {a:.27,b:3.43,who:'DOCTOR · FINNISH',text:'Kuinka kauan sinulla on ollut nielemisvaikeuksia?',translation:'How long have you had difficulty swallowing?'},
 {a:5.49,b:7.89,who:'SPOKEN TRANSLATION · ENGLISH',text:'How long have you had difficulty swallowing?',translation:'Finnish → English'},
 {a:8.69,b:11.15,who:'PATIENT · ENGLISH',text:'A few weeks. The lump is getting bigger.',translation:'English → Finnish'},
 {a:13.11,b:16.15,who:'SPOKEN TRANSLATION · FINNISH',text:'Muutama viikko. Patti kasvaa isommaksi.',translation:'A few weeks. The lump is getting bigger.'},
 {a:16.59,b:19.61,who:'DOCTOR · FINNISH',text:'Tutkin kurkkusi ja kaulasi tänään.',translation:'I will examine your throat and neck today.'},
 {a:21.44,b:23.76,who:'SPOKEN TRANSLATION · ENGLISH',text:'I will examine your throat and neck today.',translation:'Finnish → English'},
];
function KioskConversation(){
 const f=useCurrentFrame(),t=f/FPS,line=kioskLines.find(x=>t>=x.a&&t<x.b),patient=line?.who==='PATIENT';
 const beat=t<5?'You speak.':t<8.7?'Edi asks.':t<13?'Your story builds.':'A clearer next step.';
 return <>
  <Brand section="01 / Walk up. Choose a language. Start talking."/>
  <div style={{position:'absolute',left:210,top:90,width:1500,height:880,overflow:'hidden',borderRadius:24}}>
   <Video name="kiosk-short" style={{width:'100%',transform:`scale(${1+interpolate(f,[0,582],[0,.045],clamp)})`,transformOrigin:'center 48%'}}/>
  </div>
  <div style={{position:'absolute',top:170,left:0,right:0,textAlign:'center',fontSize:61,fontWeight:650,letterSpacing:-2}}>{beat}</div>
  <div style={{position:'absolute',left:520,right:520,top:865,display:'flex',alignItems:'center',gap:20}}>
   {[{name:'You',active:patient},{name:'Edi · Gemini',active:!!line&&!patient}].map((item,i)=><React.Fragment key={item.name}>
    {i>0&&<svg width="290" height="30"><path d="M0 15 H290" stroke="#d7bdcd" strokeWidth="2" strokeDasharray="5 8" strokeDashoffset={-f/2}/></svg>}
    <div style={{whiteSpace:'nowrap',borderRadius:40,padding:'16px 28px',background:item.active?C.purple:'#eee4e9',color:item.active?'white':C.muted,fontSize:26,transform:`scale(${item.active?1.03:1})`}}>{item.name}</div>
   </React.Fragment>)}
  </div>
  <div style={{position:'absolute',left:60,bottom:120,fontSize:18,color:C.muted}}>Live app · generated patient voice · genuine Gemini replies</div>
  <Caption text={line?.text||''}/>
 </>;
}
function KioskOutcome(){
 const f=useCurrentFrame(),guidance=f>=99,a=enter(f-99);
 return <>
  <Brand section="01 / From your words to your next step"/>
  <div style={{position:'absolute',left:120,top:125,color:C.purple,fontSize:28}}>
   {guidance?'Based on your symptom summary':'After the conversation'}
  </div>
  <div style={{position:'absolute',left:120,top:190,right:100,fontSize:65,lineHeight:1.1,letterSpacing:-2,fontWeight:650}}>
   {guidance?<>Speak to a medical professional<br/>as soon as possible.</>:<>Your words, summarised<br/>for review.</>}
  </div>
  {guidance&&<div style={{position:'absolute',right:120,top:120,padding:'16px 26px',borderRadius:35,background:C.purple,color:'white',fontSize:25,opacity:a,transform:`translateY(${(1-a)*10}px)`}}>High-priority referral</div>}
  <div style={{position:'absolute',left:280,top:420,width:1360,height:510,overflow:'hidden',border:'2px solid #e4d6de',borderRadius:24}}>
   <Video name="kiosk-outcome" muted style={{width:'100%'}}/>
  </div>
  <div style={{position:'absolute',left:60,bottom:120,fontSize:18,color:C.muted}}>Recorded app summary and guidance · priority for follow-up, not a diagnosis</div>
  <Narration id="guidance" delay={.1}/>
 </>;
}
function Kiosk(){
 return <>
  <Sequence durationInFrames={366}><KioskConversation/></Sequence>
  <Sequence from={366}><KioskOutcome/></Sequence>
 </>;
}
function PhysicalKiosk(){
 const f=useCurrentFrame(),move=interpolate(f,[0,228],[0,1],clamp),push=interpolate(f,[170,228],[0,1],clamp);
 return <>
  <AbsoluteFill style={{overflow:'hidden'}}>
   <Img src={staticFile('library.jpg')} style={{width:'100%',height:'100%',objectFit:'cover',transform:`scale(${1.04+move*.025}) translateX(${-move*12}px)`,filter:'brightness(.58) saturate(.75)'}}/>
   <div style={{position:'absolute',inset:0,background:'linear-gradient(90deg,#17211be8 0%,#17211bba 31%,transparent 63%)'}}/>
   <div style={{position:'absolute',left:0,right:0,top:955,height:125,background:'linear-gradient(#bd9269,#916749)',borderTop:'12px solid #d2ac81',boxShadow:'0 -8px 24px #0005'}}/>
   <div style={{position:'absolute',left:1190,top:805,width:130,height:145,background:'linear-gradient(90deg,#74787b,#d0d2d1 45%,#777a7c)',transform:'skewX(-9deg)',boxShadow:'15px 5px 25px #0004'}}/>
   <div style={{position:'absolute',left:1060,top:940,width:420,height:25,borderRadius:'50%',background:'#777d7d',boxShadow:'0 14px 16px #0008'}}/>
   <div style={{position:'absolute',left:820-push*610,top:153-push*63,width:940+push*560,padding:22-push*22,background:'#25282b',border:'3px solid #808485',borderRadius:40,boxShadow:'20px 25px 45px #0007',transform:`perspective(2200px) rotateY(${(-9+move*4)*(1-push)}deg) rotateX(${3*(1-push)}deg)`,transformOrigin:'center'}}>
    <div style={{overflow:'hidden',borderRadius:18}}><Video name="physical-kiosk" muted style={{width:'100%'}}/></div>
    <div style={{position:'absolute',left:9,top:'49%',width:6,height:6,borderRadius:9,background:'#08090a'}}/>
   </div>
  </AbsoluteFill>
  <Brand dark section="A walk-up first step"/>
  <div style={{position:'absolute',left:75,top:165,width:645,color:'white',opacity:1-push}}>
   <div style={{fontSize:23,letterSpacing:2,color:'#f4c867'}}>LIBRARIES + COMMUNITY CENTRES</div>
   <h1 style={{fontSize:79,lineHeight:1.04,letterSpacing:-3,margin:'30px 0'}}>A physical<br/>iPad kiosk.<br/>Close to home.</h1>
   <div style={{fontSize:33,lineHeight:1.45,color:'#e5e7df',marginTop:35}}>Walk up. Choose your language.<br/>Talk to Edi, powered by Gemini.</div>
   <div style={{fontSize:21,color:'#d0d5ca',marginTop:50}}>Proposed placement · live app recording</div>
  </div>
  <div style={{position:'absolute',right:30,bottom:13,fontSize:15,color:'#e6dccd'}}>Library backdrop: Alfons Morales / Unsplash · composited setting</div>
  <Narration id="welcome" delay={.1}/>
 </>;
}
function Research(){
 const t=useCurrentFrame()/FPS;
 return <>
  <Brand section="02 / An optional research sample"/>
  <div style={{position:'absolute',left:320,top:185,width:1280,height:680,overflow:'hidden',borderRadius:26}}><Video name="research-short" muted style={{width:'100%'}}/></div>
  <div style={{position:'absolute',top:108,left:0,right:0,textAlign:'center',fontSize:57,fontWeight:650,letterSpacing:-2}}>An optional signal. For clinician review.</div>
  <div style={{position:'absolute',left:480,right:480,top:877,display:'flex',alignItems:'center',justifyContent:'space-between'}}>
   {['Consent','Sample','Review'].map((label,i)=><React.Fragment key={label}>
    {i>0&&<ArrowRight color="#b9a1b2" size={28}/>}
    <div style={{padding:'18px 28px',borderRadius:40,fontSize:26,color:(t<1.3?0:t<2.9?1:2)===i?'white':C.muted,background:(t<1.3?0:t<2.9?1:2)===i?C.purple:'#e9dfe5'}}>{label}</div>
   </React.Fragment>)}
  </div>
  <div style={{position:'absolute',left:60,bottom:120,fontSize:19,color:C.muted}}>Separate consent · synthetic sample · experimental, not a cancer test</div>
  <Narration id="research" delay={.1}/>
  <Sequence from={39}><Audio src={staticFile('ah-brief.wav')} volume={.25}/></Sequence>
 </>;
}
function Handoff(){
 const t=useCurrentFrame()/FPS,f=useCurrentFrame(),active=t<4?0:t<7?1:2;
 return <>
  <Brand section="03 / Carry the story forward"/>
  <div style={{position:'absolute',left:310,top:100,width:1300,height:830,overflow:'hidden',borderRadius:25}}><Video name="handoff-live" muted style={{width:'100%'}}/></div>
  <div style={{position:'absolute',left:510,top:125,width:900,display:'flex',alignItems:'center',justifyContent:'space-between',background:C.paper,padding:'15px 25px',borderRadius:60}}>
   {['Your story','Your signature','Your next step'].map((label,i)=><React.Fragment key={label}>
    {i>0&&<ArrowRight color={C.gold}/>}
    <span style={{fontSize:28,color:i===active?C.purple:C.muted,fontWeight:i===active?700:400,transform:`scale(${i===active?1.04:1})`}}>{label}</span>
   </React.Fragment>)}
  </div>
  <div style={{position:'absolute',left:60,bottom:125,color:C.purple,fontSize:22,display:'flex',gap:12,alignItems:'center'}}><ShieldCheck size={28}/> Designed with Solana <span style={{color:C.muted,fontSize:19}}>· single use · medical details off-chain</span></div>
  <Narration id="handoff" delay={.1}/>
 </>;
}
function Doctor({mode}:{mode:'intro'|'live'|'notes'}){
 const f=useCurrentFrame(),t=f/FPS;
 const line=doctorLines.find(x=>t>=x.a&&t<x.b);
 const mostRecent=doctorLines.filter(x=>t>=x.a).at(-1);
  const current=line||mostRecent;
  const translated=current?.who.startsWith('SPOKEN');
  const english=current?.who.endsWith('ENGLISH');
  const beat=current?enter(f-current.a*FPS):enter(f);
  const primaryLeft=english?1280:80;
  const secondaryLeft=english?80:1280;
 return <>
  <Brand section="04 / At the doctor"/>
  <div style={{position:'absolute',left:745,top:101,width:424,borderRadius:34,border:'2px solid #ddd0d8',overflow:'hidden',background:'white',boxShadow:'0 20px 50px #4a1f3315'}}>
   <Video name={mode==='intro'?'doctor-intro':mode==='notes'?'doctor-notes':'doctor-live'} muted={mode!=='live'} style={{width:'100%'}}/>
  </div>
  {[{left:80,lang:'SUOMI',role:'Doctor',code:'FI'},{left:1280,lang:'ENGLISH',role:'Patient',code:'EN'}].map(item=><div key={item.code} style={{position:'absolute',left:item.left,top:150,width:550}}>
   <div style={{fontSize:21,letterSpacing:3,color:C.muted}}>{item.lang}</div>
   <div style={{fontSize:65,fontWeight:650,letterSpacing:-2,marginTop:10}}>{item.role}</div>
   <svg width="550" height="45" style={{marginTop:15}}><path d="M0 20 H550" stroke="#ddcbd6" strokeWidth="2"/><path d="M0 20 H550" stroke={C.gold} strokeWidth="5" {...evolvePath(interpolate(f,[0,35],[0,1],clamp),'M0 20 H550')}/></svg>
  </div>)}
  {mode==='live'&&current?<>
   <div style={{position:'absolute',left:primaryLeft,top:370,width:555,transform:`translateX(${(1-beat)*(english?40:-40)}px)`,opacity:beat}}>
    <div style={{fontSize:22,color:C.purple,letterSpacing:1,marginBottom:22}}>{translated?'SPOKEN TRANSLATION':english?'PATIENT SPEAKING':'DOCTOR SPEAKING'}</div>
    <div style={{fontSize:43,lineHeight:1.25,letterSpacing:-.5}}>{current.text}</div>
    <div style={{marginTop:30,fontSize:23,color:C.muted}}>{translated?'Translated aloud by ElevenLabs':'Transcribed in the live app'}</div>
   </div>
   <div style={{position:'absolute',left:secondaryLeft,top:420,width:540,color:C.muted,opacity:beat*.85}}>
    <Languages size={38} color={C.purple}/>
    <div style={{fontSize:32,lineHeight:1.35,marginTop:20}}>{current.translation}</div>
   </div>
  </>:<>
   <div style={{position:'absolute',left:80,top:390,width:555,fontSize:53,lineHeight:1.15,fontWeight:600}}>{mode==='notes'?'A shared record\nof the visit.':'Two languages.\nOne conversation.'}</div>
   <div style={{position:'absolute',left:1280,top:420,width:550,fontSize:33,lineHeight:1.45,color:C.muted}}>{mode==='notes'?'Drafted from the conversation.\nReviewed together before saving.':'The app listens, transcribes,\nand translates aloud.'}</div>
  </>}
  <div style={{position:'absolute',left:80,top:790,width:550,fontSize:22,color:C.purple,display:'flex',alignItems:'center',gap:15}}><Languages size={30}/>ElevenLabs live translation</div>
  <div style={{position:'absolute',left:1280,top:800,width:550,fontSize:19,color:C.muted}}>Recorded iOS app · generated actors<br/>Real service responses</div>
  {mode==='intro'&&<Narration id="doctor" delay={.1}/>}
 </>;
}
function WorkspaceFootage({name}:{name:VideoName}){
 const f=useCurrentFrame(),a=enter(f);
 return <div style={{opacity:a,transform:`perspective(2200px) rotateX(${(1-a)*7}deg) translateY(${(1-a)*30}px)`,transformOrigin:'center top'}}>
  <Video name={name} muted style={{width:1370}}/>
 </div>;
}
function Workspace(){
 const t=useCurrentFrame()/FPS;
 const name=t<4?'crm':t<7.2?'equity':'twin';
 const headline=name==='crm'?'A clearer view for the care team.':name==='equity'?'Find the access gap.':'Test what could help.';
 return <>
  {t<7.2&&<>
  <Brand section="05 / From individual care to national insight" dark/>
  <div style={{position:'absolute',left:65,top:110,fontSize:53,color:'white',fontWeight:650,letterSpacing:-1}}>{headline}</div>
  <div style={{position:'absolute',left:275,top:200,width:1370,height:856,borderRadius:15,overflow:'hidden',border:'2px solid #a88b9f'}}>
   <Sequence durationInFrames={120}><WorkspaceFootage name="crm"/></Sequence>
   <Sequence from={120} durationInFrames={96}><WorkspaceFootage name="equity"/></Sequence>
  </div>
  <div style={{position:'absolute',left:65,top:176,color:'#d6c2d1',fontSize:19}}>{name==='crm'?'Recorded demo workspace · synthetic examples':name==='equity'?'Public aggregate Finnish data · evidence-backed action plans':'Planning simulation · estimated effects, not clinical forecasts'}</div>
  </>}
  <Sequence durationInFrames={183}><Narration id="crm" delay={.1}/></Sequence>
  <Sequence from={216}>
   <Video name="tour-full" muted style={{width:1920,height:1080}}/>
   <Sequence durationInFrames={270}><Narration id="tour-intro" delay={.1}/></Sequence>
   <Sequence from={270} durationInFrames={66}><Narration id="tour-closure" delay={.05}/></Sequence>
   <Sequence from={342}><Narration id="tour-mobile" delay={.05}/></Sequence>
  </Sequence>
 </>;
}
function Closing(){
 const f=useCurrentFrame();
 return <>
  <Brand dark/>
  <div style={{position:'absolute',left:70,right:70,top:150,textAlign:'center',color:'white',opacity:enter(f)}}>
   <div style={{fontSize:145,fontWeight:700,letterSpacing:-7}}>Edge<span style={{color:C.gold}}>–</span>Care</div>
   <div style={{fontSize:48,marginTop:12}}>An easier first step. A clearer path to care.</div>
   <div style={{display:'flex',alignItems:'center',justifyContent:'center',gap:26,marginTop:55,fontSize:27,color:'#eed9e7'}}>
    {[[Mic,'Kiosk'],[ShieldCheck,'Private referral'],[Stethoscope,'Doctor'],[MapPin,'National insight']].map(([Icon,label]:any,i)=><React.Fragment key={label}>
     {i>0&&<ArrowRight color={C.gold} style={{opacity:enter(f-i*10)}}/>}
     <div style={{display:'flex',alignItems:'center',gap:15,opacity:enter(f-i*10),transform:`translateY(${(1-enter(f-i*10))*22}px)`}}><Icon/>{label}</div>
    </React.Fragment>)}
   </div>
   <div style={{marginTop:75,fontSize:31}}>Terry Huang <span style={{color:C.gold}}> / </span> Lissan Koirala <span style={{color:C.gold}}> / </span> Oleg Kaska <span style={{color:C.gold}}> / </span> Kridhay Mahesh</div>
   <div style={{fontSize:23,color:'#d2bbcb',marginTop:35}}>Inspired by AstraZeneca’s vision for equitable cancer care</div>
   <div style={{fontSize:20,color:'#baa0b2',marginTop:14}}>Hackathon project · not an AstraZeneca product or endorsement</div>
  </div>
  <Narration id="closing" delay={.1}/>
 </>;
}
function Scene({id}:{id:string}){
 return <AbsoluteFill style={{background:['crm','closing'].includes(id)?C.dark:C.paper,color:C.ink,fontFamily:'Arial, Helvetica, sans-serif',whiteSpace:'pre-line'}}>
  {id==='opening'?<Opening/>:id==='welcome'?<PhysicalKiosk/>:id==='kiosk'?<Kiosk/>:id==='research'?<Research/>:id==='handoff'?<Handoff/>:id==='doctor'?<Doctor mode="intro"/>:id==='consultation'?<Doctor mode="live"/>:id==='notes'?<Doctor mode="notes"/>:id==='crm'?<Workspace/>:<Closing/>}
 </AbsoluteFill>;
}
function Trailer(){
 return <AbsoluteFill>
  <Audio src={staticFile('score.wav')} volume={f=>interpolate(f,[0,45,total-100,total],[0,.17,.17,0],clamp)}/>
  <TransitionSeries>{scenes.map((s,i)=><React.Fragment key={s.id}>
   {i>0&&(['welcome','handoff','crm'].includes(s.id)
    ?<TransitionSeries.Transition presentation={wipe({direction:'from-left'})} timing={linearTiming({durationInFrames:transitionFrames})}/>
    :<TransitionSeries.Transition presentation={fade()} timing={linearTiming({durationInFrames:transitionFrames})}/>)}
   <TransitionSeries.Sequence durationInFrames={s.frames}><Scene id={s.id}/></TransitionSeries.Sequence>
  </React.Fragment>)}</TransitionSeries>
 </AbsoluteFill>;
}
registerRoot(()=> <Composition id="EdgeCareTrailerV4" component={Trailer} width={1920} height={1080} fps={FPS} durationInFrames={total}/>);
