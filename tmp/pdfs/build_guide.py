from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT, TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak, KeepTogether
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfbase import pdfmetrics
from reportlab.lib.colors import HexColor
from pathlib import Path

OUT = Path('output/pdf/master-campus-workflow-api-guide.pdf')
OUT.parent.mkdir(parents=True, exist_ok=True)
NAVY = HexColor('#142c55'); BLUE = HexColor('#386ee8'); PALE = HexColor('#edf3ff')
INK = HexColor('#23344d'); MUTED = HexColor('#667895'); LINE = HexColor('#dce5f2')
GREEN = HexColor('#148b6a'); AMBER = HexColor('#a56712'); RED = HexColor('#ae3f48')

styles = getSampleStyleSheet()
styles.add(ParagraphStyle(name='CoverTitle', parent=styles['Title'], fontName='Helvetica-Bold', fontSize=30, leading=36, textColor=NAVY, alignment=TA_LEFT, spaceAfter=10))
styles.add(ParagraphStyle(name='CoverSub', parent=styles['Normal'], fontName='Helvetica', fontSize=13, leading=20, textColor=MUTED, spaceAfter=8))
styles.add(ParagraphStyle(name='H1x', parent=styles['Heading1'], fontName='Helvetica-Bold', fontSize=20, leading=25, textColor=NAVY, spaceBefore=3, spaceAfter=11, keepWithNext=True))
styles.add(ParagraphStyle(name='H2x', parent=styles['Heading2'], fontName='Helvetica-Bold', fontSize=12, leading=16, textColor=BLUE, spaceBefore=9, spaceAfter=5, keepWithNext=True))
styles.add(ParagraphStyle(name='Bodyx', parent=styles['BodyText'], fontName='Helvetica', fontSize=9.2, leading=13.5, textColor=INK, spaceAfter=6))
styles.add(ParagraphStyle(name='Smallx', parent=styles['BodyText'], fontName='Helvetica', fontSize=8, leading=11, textColor=MUTED, spaceAfter=3))
styles.add(ParagraphStyle(name='Cellx', parent=styles['BodyText'], fontName='Helvetica', fontSize=8.1, leading=11, textColor=INK))
styles.add(ParagraphStyle(name='CellHeadx', parent=styles['BodyText'], fontName='Helvetica-Bold', fontSize=8, leading=10, textColor=colors.white))
styles.add(ParagraphStyle(name='Calloutx', parent=styles['BodyText'], fontName='Helvetica', fontSize=9, leading=13, textColor=NAVY))
styles.add(ParagraphStyle(name='Stepx', parent=styles['BodyText'], fontName='Helvetica', fontSize=9, leading=13, textColor=INK, leftIndent=16, firstLineIndent=-16, spaceAfter=5))

def P(text, style='Bodyx'):
    return Paragraph(text, styles[style])

def bullets(items):
    return [P('&bull;&nbsp; ' + x) for x in items]

def table(rows, widths, header=True):
    data=[]
    for ri,row in enumerate(rows):
        data.append([P(str(c), 'CellHeadx' if header and ri==0 else 'Cellx') for c in row])
    t=Table(data, colWidths=widths, repeatRows=1 if header else 0, hAlign='LEFT')
    cmds=[('VALIGN',(0,0),(-1,-1),'TOP'),('LEFTPADDING',(0,0),(-1,-1),7),('RIGHTPADDING',(0,0),(-1,-1),7),('TOPPADDING',(0,0),(-1,-1),6),('BOTTOMPADDING',(0,0),(-1,-1),6),('GRID',(0,0),(-1,-1),.35,LINE),('ROWBACKGROUNDS',(0,1 if header else 0),(-1,-1),[colors.white,HexColor('#f7f9fd')])]
    if header: cmds.append(('BACKGROUND',(0,0),(-1,0),NAVY))
    t.setStyle(TableStyle(cmds)); return t

def callout(title, text, color=BLUE):
    t=Table([[P(f'<b>{title}</b><br/>{text}','Calloutx')]], colWidths=[170*mm])
    t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,-1),PALE),('BOX',(0,0),(-1,-1),.7,color),('LINEBEFORE',(0,0),(0,-1),3,color),('LEFTPADDING',(0,0),(-1,-1),10),('RIGHTPADDING',(0,0),(-1,-1),10),('TOPPADDING',(0,0),(-1,-1),8),('BOTTOMPADDING',(0,0),(-1,-1),8)]))
    return t

def header_footer(canvas, doc):
    canvas.saveState(); w,h=A4
    if doc.page>1:
        canvas.setStrokeColor(LINE); canvas.line(20*mm,h-15*mm,w-20*mm,h-15*mm)
        canvas.setFont('Helvetica-Bold',8); canvas.setFillColor(NAVY); canvas.drawString(20*mm,h-11.5*mm,'MASTER CAMPUS  /  WORKFLOW GUIDE')
        canvas.setFont('Helvetica',8); canvas.setFillColor(MUTED); canvas.drawRightString(w-20*mm,11*mm,f'{doc.page}')
        canvas.setStrokeColor(LINE); canvas.line(20*mm,15*mm,w-20*mm,15*mm)
    canvas.restoreState()

story=[]
# Cover
story += [Spacer(1,24*mm), P('MASTER<br/>CAMPUS','CoverTitle'), P('App workflow, roles, database aur API guide','CoverSub'), Spacer(1,7*mm)]
cover=Table([[P('<b>Is guide mein kya milega</b><br/><br/>Student, teacher aur campus admin ka workflow<br/>Campus - session - branch - class hierarchy<br/>Supabase login aur database requests ka flow<br/>AI assistant, quiz generator aur file uploads<br/>Setup dependencies aur practical limitations','Calloutx')]],colWidths=[166*mm],rowHeights=[46*mm])
cover.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,-1),PALE),('BOX',(0,0),(-1,-1),.8,BLUE),('LEFTPADDING',(0,0),(-1,-1),14),('TOPPADDING',(0,0),(-1,-1),12)])); story += [cover, Spacer(1,18*mm)]
story += [P('Code walkthrough | 7 October 2026','Smallx'), P('Yeh document repository ke maujooda frontend, API code aur Supabase migrations ko dekhkar banaya gaya hai. Yeh live Supabase project ka health audit nahin hai. Kaunse features actual production mein chalenge, woh deployed Edge Functions, applied SQL migrations, RLS policies, Storage policies aur secrets par depend karta hai.','Bodyx'), PageBreak()]

# Architecture
story += [P('1. App ka overall architecture','H1x'), P('Browser ya phone par React + Vite frontend chalta hai. User sign in ke baad Supabase Auth session paata hai. Frontend session token ke saath Supabase database/Storage ko directly call karta hai; row access ko database ke RLS policies control karte hain. AI requests ka current UI path Supabase Edge Function hai.','Bodyx')]
arch=Table([[P('<b>Phone / PC browser</b><br/>React + Vite UI','Cellx'),P('<b>Supabase Auth</b><br/>user session + JWT','Cellx'),P('<b>Postgres + Storage</b><br/>RLS protected data','Cellx')],[P('Responsive web app / installable PWA shell','Smallx'),P('<b>campus-register</b><br/>signup approval workflow','Cellx'),P('<b>campus-ai</b><br/>AI assistant + quiz','Cellx')]],colWidths=[56*mm,56*mm,56*mm])
arch.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),PALE),('BACKGROUND',(0,1),(-1,1),colors.white),('GRID',(0,0),(-1,-1),.5,LINE),('VALIGN',(0,0),(-1,-1),'TOP'),('LEFTPADDING',(0,0),(-1,-1),8),('TOPPADDING',(0,0),(-1,-1),8),('BOTTOMPADDING',(0,0),(-1,-1),8)]));story += [arch, Spacer(1,7)]
story += [table([['Part','Role'],['React frontend','Login screens, dashboards, forms, attendance UI, upload controls, quiz display. Main file: src/main.jsx.'],['Supabase Auth','Email/password sign-in; JWT session; auth state restored on refresh. Client setup: src/supabase.js.'],['Supabase Postgres','Profiles, campuses, sessions, branches, classes, memberships, attendance, notices, assignments, reviews. RLS limits row access.'],['Supabase Storage','Private class-materials and assignment-submissions buckets; uploads and signed download links.'],['Supabase Edge Functions','campus-register creates approved-by-admin account requests; campus-ai calls Groq for AI work.'],['Node/Express API','server/index.js exposes /api/health, /api/assistant and /api/quiz on port 8787. Separate/duplicate AI backend path; current React UI invokes campus-ai Edge Function, not these Node AI routes.']], [43*mm,125*mm]), Spacer(1,8), callout('Important: frontend ka live AI path','Ask Campus Buddy aur quiz generator `supabase.functions.invoke("campus-ai", ...)` chalate hain. Vite ka /api proxy Node server ko route karta hai, lekin current UI mein `/api/assistant` ya `/api/quiz` call nahin mila. Dono backends ko ek hi live path samajhna galat hoga.')]
story += [PageBreak()]

# hierarchy
story += [P('2. Campus data structure','H1x'), P('App ka intended flow ek campus ke andar academic session, session ke andar branch, aur branch/session ke andar class ya batch hai. Teacher branch-subject aur explicit class assignment ke through classes se judta hai. Students campus enrollment ke baad class membership request bhejte hain.','Bodyx')]
story += [table([['Level','Meaning / link'],['Campus','Campus admin registration par campus aur unique Campus ID banta hai.'],['Academic session','Campus ka session; jaise 2026-27.'],['Session + branch','`session_branches` batata hai kaunsi branch kis academic session mein active hai.'],['Branch + subject','Branch apne subjects rakhti hai; subject codes branch context mein define hote hain.'],['Class / batch','Class branch aur session se linked hoti hai; subjects `class_subjects` ke through link hote hain.'],['Teacher mapping','`branch_teachers` branch-subject level; `class_teachers` specific class level assignment. Ek teacher multiple classes/branches le sakta hai.'],['Student membership','`campus_enrollments` campus/branch/session affiliation; `class_memberships` specific class request/approval.']], [42*mm,126*mm])]
story += [P('Campus admin ka initial setup','H2x')]
for i,txt in enumerate(['Admin account create/confirm karke login karta hai; campus record aur Campus ID milta hai.','Academic session banata hai, branches banata hai aur har branch ko session se link karta hai.','Branch subjects aur classes/batches define karta hai; class ke subjects select karta hai.','Teachers ki pending applications review/approve karta hai; branch-subject ya class teaching assignments karta hai.','Students Campus ID, session, branch aur college-issued registration number ke saath apply karte hain; admin campus application approve karta hai.','Student class code se class membership request bhejta hai; assigned teacher membership approve karta hai.'],1): story.append(P(f'<b>{i}.</b> {txt}','Stepx'))
story += [callout('Current code mein class creation','`src/campusData.js` `create_campus_class` database RPC invoke karta hai. Latest relevant migration `20261014000000_fix_campus_admin_class_rls.sql` hai. Agar RPC/migration live database mein apply nahin hui, ya RLS helper ka role/campus mapping mismatch hai, class creation RLS error de sakta hai.',AMBER),PageBreak()]

# roles
story += [P('3. Login, registration aur approvals','H1x'), P('Login UI role picker dikhata hai: Student, Teacher, Campus Admin; platform-admin path alag privileged use ke liye hai. Sign-in ke baad app `profiles` se role/status load karta hai aur selected login role actual profile role se match karta hai.','Bodyx')]
story += [table([['Action','Code path','Approval result'],['Login','Supabase `auth.signInWithPassword`; then `profiles` read.','Wrong role selected ho to sign out karke matching role choose karne ko kehta hai. Suspended account block hota hai.'],['Campus admin signup','Direct Supabase `auth.signUp`; metadata includes campus name/address.','DB trigger `handle_new_user` profile/campus/admin relationship create karta hai. Email confirmation Auth settings par depend karta hai.'],['Teacher signup','`campus-register` Edge Function; campus ID, email/password, profile metadata.','Function service-role Auth user create karta hai and pending campus enrollment/profile. Campus admin approval ke baad teacher workspace.'],['Student signup','`campus-register`; Campus ID, session, branch, college registration number.','Function campus and session-branch validate, duplicate college number check; campus admin approval. Class membership separately requested/teacher-approved.']], [32*mm,69*mm,67*mm])]
story += [P('College registration number aur app code','H2x'), P('Student ka college-issued registration number user enter karta hai. Yeh campus ke andar duplicate nahin hona chahiye, aur roster attendance isi number ke mutabik sort hota hai. App ka generated internal student code alag identifier hai; dono ko confuse na karein. Registration uniqueness ke liye migrations `20261011000000_student_registration_candidate_key.sql` aur `20261012000000_college_registration_number.sql` current chain ka hissa hain.','Bodyx')]
story += [callout('Live setup check','Edge Functions ko deploy hona chahiye; campus-ai ke liye `GROQ_API_KEY` aur model secret set hona chahiye. SQL migrations ko correct order mein Supabase project par apply karna hoga. Frontend `.env` mein `VITE_SUPABASE_URL` aur `VITE_SUPABASE_ANON_KEY` public client config hain; service-role key kabhi Vite env/bundled frontend mein nahin rakhein.',RED),PageBreak()]

# role features
story += [P('4. Har role app mein kya karta hai','H1x'), P('Navigation aur pages role ke hisab se change hote hain. Data calls current user/campus/class permissions se scope hone chahiye; dashboard counts aur screens tabhi real data dikhayenge jab Supabase config, database schema aur RLS sahi ho.','Bodyx')]
story += [table([['Role','Available workflow (current UI)'],['Campus admin','Overview; sessions; branches; teaching assignments; students/teachers approvals; routines; attendance; notices; calendar; activity log; support; classes. Teacher/student directory, approval, campus setup and exports.'],['Teacher','Overview; assigned classes; attendance roster; syllabus/material uploads; assignments; student reviews; notices; support. Can access student/class data only through assigned campus/class paths subject to RLS.'],['Student','Overview; my classes; attendance; assignments/submissions; study library/materials; calendar/notices; teacher reviews; help. Class join request by class code; study progress checkboxes.'],['Platform admin','Campus list/overview path intended for platform-level administration. This is separate from campus admin role and should be tightly controlled.']], [35*mm,133*mm])]
story += [P('Class assignment vs branch assignment','H2x'), P('Branch-subject assignment ka matlab teacher ko branch mein subject responsibility dena hai. Class ka access tabhi reliable hota hai jab `class_teachers` mein teacher-class row ho. Latest class RPC branch teachers ko selected class subjects ke mutabik auto-link kar sakta hai, lekin existing classes ke liye sync/assignment migration and UI action matter karte hain. Sirf branch linked dikhna, class assigned hone ka proof nahin hai.','Bodyx')]
story += [P('Notice, assignment, material, progress','H2x'), P('Teacher class ya branch context choose karke notice, assignment, syllabus unit aur learning material publish karta hai. Student enrolled class ki allowed resources dekhta hai. Study section ke checkbox progress ko save karte hain. Reviews/ratings role aur policy checks ke under submit aur read hote hain. File metadata database mein aur binary private Supabase Storage mein rehta hai.','Bodyx'),PageBreak()]

# API
story += [P('5. API calls kaise chalti hain','H1x'), P('Normal application requests Supabase JavaScript client se direct PostgREST/Storage/Auth endpoints ko jaati hain. Browser apna Supabase session JWT attach karta hai. Database RLS decide karta hai ki user ka SELECT/INSERT/UPDATE allowed hai ya nahin. Supabase ka anon/publishable key frontend identifier hai, authorization ka replacement nahin.','Bodyx')]
story += [table([['Feature','Frontend request','Backend action'],['Profile load','`from("profiles").select(...).eq("id", user.id)`','RLS ke mutabik apna/authorized profile return.'],['Campus signup','`auth.signUp(...)`','Supabase Auth + DB trigger; campus/profile/admin relation creation.'],['Teacher/student registration','`functions.invoke("campus-register", {body})`','Function campus code/session-branch validate karti hai; service-role Auth user create; profile/enrollment pending set.'],['Create class','`rpc("create_campus_class", {p_class_data, p_subject_ids})`','SQL function admin campus scope, active session-branch and subject validations; class, subjects, teacher links insert.'],['Read/write app records','`from(table).select/insert/update/upsert(...)`','Supabase PostgREST; RLS policy per operation/table.'],['Upload/download','Storage upload to private bucket; metadata in database; signed URL for read','Storage object policy and database policies both apply.'],['AI/quiz','`functions.invoke("campus-ai", {body})`','Edge Function verifies bearer user + profile/role/access; Groq API call; quiz result persisted.']], [34*mm,64*mm,70*mm])]
story += [P('Class creation API sequence','H2x')]
for i,txt in enumerate(['Admin form se branch, session, class name/code, subjects collect hote hain.','Frontend Supabase RPC `create_campus_class` call karti hai current auth token ke saath.','Postgres security-definer function caller ke campus-admin membership, session/branch relation, subject branch validate karta hai.','Valid hone par class insert, class-subject links aur applicable branch-teacher class links insert hote hain.','RLS/RPC error aaya to frontend ko error text milta hai; UI success tabhi dikhana chahiye jab RPC success ho.'],1): story.append(P(f'<b>{i}.</b> {txt}','Stepx'))
story += [PageBreak()]

# attendance + uploads
story += [P('6. Attendance aur files','H1x'), P('Attendance teacher ke selected class aur date ke liye roster se start hoti hai. Roster active class members se load hota hai aur college registration number ke hisab se sort kiya jaata hai; absent number ho to app registration/internal code fallback ho sakta hai.','Bodyx')]
story += [P('Attendance save sequence','H2x')]
for i,txt in enumerate(['Teacher class + date select karta hai; student status checkbox/selector se present/absent/late/excused mark karta hai.','Normal day par `attendance_sessions` class/date ke liye upsert hota hai, uske baad per-student `attendance_records` upsert.','Holiday/class suspended mark hone par session suspended save hota hai aur student absences create nahin hote.','Student/admin pages attendance history read karke totals/percentage dikhate hain; RLS unke allowed scope ko govern karta hai.'],1): story.append(P(f'<b>{i}.</b> {txt}','Stepx'))
story += [callout('Attendance PDF ka actual behaviour','Teacher AI attendance review counts/percentages ka summary `campus-ai` ko bhejta hai. PDF export `window.print()` / browser Print > Save as PDF use karta hai. Current code mein AI-generated PDF file ka code nahin mila; AI review aur PDF printing alag features hain.',AMBER),Spacer(1,8)]
story += [P('Upload aur student submissions','H2x'), P('Frontend `src/fileRules.js` file type/size validate karta hai: PDF/CSV, max 10 MB; resource links HTTP/HTTPS hone chahiye. Teacher binary `class-materials` private bucket mein upload karta hai aur material/assignment/syllabus record database mein save karta hai. Student assignment file `assignment-submissions` bucket mein upload aur submission metadata database mein save hoti hai. Download ke liye signed URL milta hai.','Bodyx')]
story += [callout('Quiz ke uploaded PDF ka text extraction','Quiz generator binary PDF ko OCR/read nahin karta. Quiz source text database ke material/assignment/syllabus notes ya `content_text` description se aata hai. Isliye teacher ko useful lesson notes/text save karna hoga; sirf PDF upload se meaningful quiz guaranteed nahin.',RED),PageBreak()]

# AI
story += [P('7. AI assistant aur quiz generator','H1x'), P('AI path UI se Supabase Edge Function `campus-ai` tak jaata hai, phir Groq API. Groq key client/browser mein nahin honi chahiye; Edge Function environment secret `GROQ_API_KEY` use karta hai. Model secret `GROQ_MODEL` current code/config mein `llama-3.3-70b-versatile` default hai.','Bodyx')]
story += [table([['AI action','What happens'],['Campus Buddy','UI current role/context ka message `action: assistant` ke saath Edge Function ko bhejta hai. Student message mein class count/attendance context add hota hai. Function user/session validate karke Groq response return karti hai.'],['Quiz generation','Student source list se material/assignment/syllabus source, count (5/10/15), difficulty choose karta hai. Frontend quiz action plus source kind/id invoke karta hai.'],['Authorization','Function JWT check karke active profile dekhti hai; quiz ke liye student role, source record aur active class membership validate karti hai.'],['Prompt input','Source ka saved text/notes use hote hain; kam text hua to request reject hoti hai. Current UI >30 chars guard; Edge Function source text >=40 char enforce karta hai.'],['Groq output','Function structured JSON multiple-choice questions generate karwati, option/index/explanation validate karti hai.'],['Persistence + score','Generated quiz database `generated_quizzes` mein save hota hai. Frontend answers score karta hai, completion score/time update karta hai.']], [36*mm,132*mm])]
story += [P('AI request flow, step-by-step','H2x')]
for i,txt in enumerate(['Browser `supabase.functions.invoke` current user JWT ke saath request bhejta hai.','Edge Function token ko Supabase Auth se verify karke profile/account status aur action-specific access check karti hai.','Quiz action source record service-role client se read karta hai, par class membership/role checks ke baad hi content use karta hai.','Function GROQ_API_KEY ko server-side rakhti hai aur Groq chat completion endpoint ko prompt bhejti hai.','Response validate hota hai; quiz DB mein persist hota hai; answer UI par return hote hain.'],1): story.append(P(f'<b>{i}.</b> {txt}','Stepx'))
story += [callout('Server API alag hai','Express server mein `/api/assistant` aur `/api/quiz` routes Groq call kar sakte hain. Vite dev server `/api` ko port 8787 par proxy karta hai, lekin current React UI ka observed AI call Supabase Edge Function hai. Node routes ko use karna ho to frontend ko explicitly un routes par point karna padega.'),PageBreak()]

# setup limitations
story += [P('8. Setup, security aur known boundaries','H1x'), P('Development mein root directory se `npm run dev` web + Node server start karta hai. Web `http://localhost:5173`; Node health/API port `8787`. Phone par same Wi-Fi test ke liye Vite network URL kholna, server origin/redirect settings sahi rakhna aur Supabase Auth redirect URLs mein intended origins allow karna zaruri hai. PWA install behavior browser/device ke hisab se badalta hai.','Bodyx')]
story += [table([['Config','Where','Purpose'],['VITE_SUPABASE_URL','Frontend `.env`','Supabase project URL; browser client.'],['VITE_SUPABASE_ANON_KEY','Frontend `.env`','Public anon/publishable key; keep RLS correct.'],['SUPABASE_URL','Node server env','Server-side Supabase project URL.'],['SUPABASE_SERVICE_ROLE_KEY','Node/Edge secret only','Privileged backend operations; never expose in Vite/browser.'],['GROQ_API_KEY','Edge Function / server secret','Groq API authentication; server-side only.'],['GROQ_MODEL','Edge Function / server env','Model selection.'],['APP_ORIGIN','Node server env','CORS allowed frontend origin.']], [47*mm,48*mm,73*mm])]
story += [P('What this code does not prove on its own','H2x')]
story += bullets(['Live deployment par har migration applied hai ya nahin. File name migration order batata hai, database state nahin.','RLS aur Storage policies live project mein installed, correct, and secure hain ya nahin. A denied request may be a policy/membership mismatch; frontend code cannot override it.','`campus-register`/`campus-ai` functions deployed hain, required secrets populated hain, and current production frontend points to the same project.','Groq free quota, Supabase quotas/email limits, and production availability. Provider settings can change.','AI factual accuracy. Teacher should review generated quizzes; student data shared in AI prompts should be minimized.'] )
story += [callout('Useful troubleshooting clue','`Could not embed because more than one relationship...` usually means Supabase query needs an explicit foreign-key relation name. `new row violates row-level security policy` means caller/token/policy/campus membership/RPC path needs checking. `Edge Function returned a non-2xx` means inspect function logs/response body and deployed function secrets; the UI message alone does not identify the root cause.',AMBER),Spacer(1,8)]
story += [P('Project locations','H2x'), P('Frontend: `src/main.jsx`, `src/campusData.js`, `src/supabase.js`, `src/fileRules.js`<br/>Functions: `supabase/functions/campus-register/index.ts`, `supabase/functions/campus-ai/index.ts`<br/>Node API: `server/index.js`<br/>Database migrations: `supabase/migrations/` (latest observed: `20261014000000_fix_campus_admin_class_rls.sql`)','Smallx'), Spacer(1,8), P('End of guide','Smallx')]

doc=SimpleDocTemplate(str(OUT),pagesize=A4,rightMargin=21*mm,leftMargin=21*mm,topMargin=22*mm,bottomMargin=21*mm,title='Master Campus App Workflow and API Guide',author='OpenAI Codex',subject='Code walkthrough of Master Campus app workflows, Supabase API and AI integration')
doc.build(story,onFirstPage=header_footer,onLaterPages=header_footer)
print(OUT.resolve())
