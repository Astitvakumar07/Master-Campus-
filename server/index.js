import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import { createClient } from '@supabase/supabase-js';
import { pathToFileURL } from 'node:url';
import { allowedOrigins, validateQuizQuestions, WindowRateLimiter } from './security.js';

const app=express();
app.disable('x-powered-by');
if(process.env.TRUST_PROXY==='1')app.set('trust proxy',1);
const originAllowlist=allowedOrigins({configured:process.env.APP_ORIGIN||'',production:process.env.NODE_ENV==='production'});
if(process.env.NODE_ENV==='production'&&!process.env.APP_ORIGIN)throw new Error('APP_ORIGIN must list the production web origin(s), separated by commas.');
app.use((req,res,next)=>{res.set({
  'X-Content-Type-Options':'nosniff',
  'X-Frame-Options':'DENY',
  'Referrer-Policy':'no-referrer',
  'Permissions-Policy':'camera=(), microphone=(), geolocation=()',
  'Cache-Control':'no-store',
});if(process.env.NODE_ENV==='production')res.set('Strict-Transport-Security','max-age=31536000; includeSubDomains');next()});
app.use(cors({origin(origin,callback){if(!origin||originAllowlist.has(origin))return callback(null,true);return callback(new Error('Origin is not allowed.'))},credentials:false,methods:['GET','POST','OPTIONS'],allowedHeaders:['Authorization','Content-Type']}));
app.use(express.json({limit:'16kb',strict:true}));
const port=Number(process.env.PORT||8787);
const supabaseUrl=process.env.SUPABASE_URL;
const serviceKey=process.env.SUPABASE_SERVICE_ROLE_KEY;
const groqKey=process.env.GROQ_API_KEY;
const model=process.env.GROQ_MODEL||'llama-3.3-70b-versatile';
const adminClient=supabaseUrl&&serviceKey?createClient(supabaseUrl,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}}):null;
const aiLimiter=new WindowRateLimiter({limit:24,windowMs:60_000,maxKeys:10_000});
const applyAiLimit=(req,res,next)=>{const result=aiLimiter.consume(req.ip||'unknown');if(!result.allowed){res.set('Retry-After',String(Math.ceil(result.retryAfterMs/1000)));return res.status(429).json({error:'You have reached the short-term AI request limit. Please try again in a minute.'})}next()};

app.get('/api/health',(_req,res)=>res.json({ok:true}));
app.post('/api/assistant',applyAiLimit,async(req,res)=>{
  if(!groqKey)return res.status(503).json({error:'Campus Buddy is not configured yet. Add the Groq key on the server.'});
  if(!adminClient)return res.status(503).json({error:'Supabase server configuration is missing.'});
  const auth=req.get('authorization')||'';
  const token=auth.startsWith('Bearer ')?auth.slice(7):'';
  if(!token)return res.status(401).json({error:'Please sign in to use Campus Buddy.'});
  const message=typeof req.body?.message==='string'?req.body.message.trim().slice(0,4000):'';
  if(!message)return res.status(400).json({error:'Add a question first.'});
  try{
    const {data:{user},error:userError}=await adminClient.auth.getUser(token);
    if(userError||!user)return res.status(401).json({error:'Your session has expired. Please sign in again.'});
    const {data:profile,error:profileError}=await adminClient.from('profiles').select('role,account_status,full_name').eq('id',user.id).single();
    if(profileError||!profile)return res.status(403).json({error:'Campus profile not found.'});
    if(profile.account_status!=='active')return res.status(403).json({error:'Your campus account is awaiting approval.'});
    const role=profile.role;
    const {data:completion,error:groqError}=await fetch('https://api.groq.com/openai/v1/chat/completions',{
      method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${groqKey}`},
      body:JSON.stringify({model,temperature:.35,max_tokens:650,messages:[
        {role:'system',content:`You are Campus Buddy, the kind and concise study and campus assistant inside Master Campus. The signed-in user's campus role is ${role}. Help with learning, classes, attendance, assignments and campus information. Never reveal private information about another student or teacher. Do not claim an action was saved unless a real tool explicitly confirms it. If asked for personal records, direct the user to the relevant authorized campus page.`},
        {role:'user',content:message},
      ]}),
    });
    const body=await completion.json();
    if(!completion.ok)throw new Error(body.error?.message||`Groq returned ${completion.status}`);
    const answer=body.choices?.[0]?.message?.content?.trim();
    if(!answer)throw new Error('The AI returned an empty answer.');
    res.json({answer,model});
  }catch(error){console.error('assistant request failed:',error.message);res.status(502).json({error:'Campus Buddy could not answer right now. Please try again.'})}
});

app.post('/api/quiz',applyAiLimit,async(req,res)=>{
  if(!groqKey||!adminClient)return res.status(503).json({error:'Configure the Supabase server and Groq keys before generating quizzes.'});
  const auth=req.get('authorization')||'',token=auth.startsWith('Bearer ')?auth.slice(7):'';
  if(!token)return res.status(401).json({error:'Please sign in before generating a quiz.'});
  try{
    const {data:{user},error:userError}=await adminClient.auth.getUser(token);
    if(userError||!user)return res.status(401).json({error:'Your session has expired. Please sign in again.'});
    const {data:profile,error:profileError}=await adminClient.from('profiles').select('role,account_status').eq('id',user.id).single();
    if(profileError||!profile||profile.account_status!=='active')return res.status(403).json({error:'An active campus account is required.'});
    if(profile.role!=='student')return res.status(403).json({error:'Quiz generation is available to active students.'});
    const {sourceKind,sourceId}=req.body||{};
    const tables={material:['materials','title,description,content_text,class_id'],assignment:['assignments','title,description,class_id'],syllabus:['syllabus_units','title,description,class_id']};
    if(!tables[sourceKind]||typeof sourceId!=='string'||! /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(sourceId))return res.status(400).json({error:'Choose a valid class material, assignment, or syllabus unit.'});
    const [table,fields]=tables[sourceKind];
    const {data:source,error:sourceError}=await adminClient.from(table).select(fields).eq('id',sourceId).single();
    if(sourceError||!source)return res.status(404).json({error:'That study source could not be found.'});
    const {data:membership,error:membershipError}=await adminClient.from('class_memberships').select('id').eq('class_id',source.class_id).eq('student_id',user.id).eq('status','active').maybeSingle();
    if(membershipError||!membership)return res.status(403).json({error:'You are not enrolled in the class for that material.'});
    const sourceText=[source.title,source.description,source.content_text].filter(Boolean).join('\n\n').slice(0,12000);
    if(sourceText.length<40)return res.status(422).json({error:'This item needs a fuller description or lesson notes before a useful quiz can be generated.'});
    const requestedCount=Number(req.body.count||5),count=[5,10,15].includes(requestedCount)?requestedCount:5;
    const difficulty=['warmup','mixed','challenge'].includes(req.body.difficulty)?req.body.difficulty:'mixed';
    const completion=await fetch('https://api.groq.com/openai/v1/chat/completions',{
      method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${groqKey}`},
      body:JSON.stringify({model,temperature:.25,max_tokens:2600,response_format:{type:'json_object'},messages:[
        {role:'system',content:`Create a fair study quiz from only the supplied campus course text. Return JSON with one property questions: an array of exactly ${count} items. Each item must have question (string), options (array of exactly 4 strings), answer_index (integer 0-3), and explanation (string). Difficulty: ${difficulty}. Do not add unsupported facts.`},
        {role:'user',content:`Course material title: ${source.title}\n\nCourse material:\n${sourceText}`},
      ]}),
    });
    const result=await completion.json();if(!completion.ok)throw new Error(result.error?.message||'Groq could not generate the quiz.');
    let parsed;try{parsed=JSON.parse(result.choices?.[0]?.message?.content||'{}')}catch{throw new Error('The AI returned an unreadable quiz. Try again.')}
    const questions=Array.isArray(parsed.questions)?parsed.questions.slice(0,count):[];
    if(!validateQuizQuestions(questions,count))throw new Error('The AI returned an incomplete quiz. Try again.');
    const {data:quiz,error:saveError}=await adminClient.from('generated_quizzes').insert({class_id:source.class_id,material_id:sourceKind==='material'?sourceId:null,student_id:user.id,title:`Practice quiz · ${source.title}`,questions}).select('id,title,questions,created_at').single();
    if(saveError)throw saveError;
    res.json(quiz);
  }catch(error){console.error('quiz generation failed:',error.message);res.status(502).json({error:'Quiz generation failed. Please try again.'})}
});

app.use((error,req,res,_next)=>{if(error?.message==='Origin is not allowed.')return res.status(403).json({error:'This app origin is not allowed to use the campus API.'});if(error?.type==='entity.too.large')return res.status(413).json({error:'Request is too large.'});console.error('API request failed:',error?.message||'Unknown error');res.status(400).json({error:'The request could not be processed.'})});

export { app };
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){app.listen(port,'0.0.0.0',()=>console.log(`Master Campus API listening on ${port}`))}
