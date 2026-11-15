import {bundle} from '@remotion/bundler';
import {selectComposition,renderMedia,renderStill} from '@remotion/renderer';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=path.dirname(fileURLToPath(import.meta.url));
const output=path.join(root,'out');
const browserExecutable=process.env.REMOTION_BROWSER_EXECUTABLE;
const serveUrl=await bundle({entryPoint:path.join(root,'src/index.tsx'),publicDir:path.join(root,'public')});
const composition=await selectComposition({serveUrl,id:'EdgeCareTrailerV4',browserExecutable});
if(composition.durationInFrames/composition.fps>125)throw new Error('Hard cap exceeded');
await fs.mkdir(path.join(output,'review'),{recursive:true});
if(process.argv.includes('--preview')){
 for(const time of [23,28,31,33,35,39,57,64,87,91,96,101,105,108,113]){
  await renderStill({serveUrl,composition,frame:Math.round(time*30),output:path.join(output,`review/${time}.png`),browserExecutable,scale:.5});
  console.log('Reviewed',time);
 }
} else {
 let last=-1;
 await renderMedia({serveUrl,composition,codec:'h264',audioCodec:'aac',crf:18,outputLocation:path.join(output,'EdgeCare-Trailer-V4-render.mp4'),browserExecutable,concurrency:6,
  onProgress:p=>{let percent=Math.floor(p.progress*20)*5;if(percent!==last){last=percent;console.log(`${percent}%`);}}
 });
}
console.log('Runtime',composition.durationInFrames/composition.fps);
