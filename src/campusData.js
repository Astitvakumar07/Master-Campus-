import { supabase, isSupabaseConfigured } from './supabase.js';
import { cleanResourceUrl, validateCampusFile } from './fileRules.js';

function requireCampus(){if(!isSupabaseConfigured||!supabase)throw new Error('Connect Supabase in .env before saving campus data.')}
function check({data,error}){if(error)throw error;return data}

export async function loadMyClasses(user,role){
  requireCampus();
  if(role==='student')return check(await supabase.from('class_memberships').select('id,status,class:classes(id,code,name,department,course_level,term,description,branch_id,branch:branches(name,code))').eq('student_id',user.id).eq('status','active')).map(x=>x.class).filter(Boolean);
  if(role==='teacher'){
    const direct=await supabase.from('class_teachers').select('class_id').eq('teacher_id',user.id);
    if(direct.error)throw direct.error;
    const classIds=[...new Set((direct.data||[]).map(x=>x.class_id).filter(Boolean))];
    if(!classIds.length)return [];
    return check(await supabase.from('classes').select('id,code,name,department,course_level,term,description,branch_id').in('id',classIds).eq('is_archived',false));
  }
  return check(await supabase.from('classes').select('id,code,name,department,course_level,term,description,branch_id,academic_session_id').eq('is_archived',false).order('code'));
}
export async function requestClassEnrollment(code,user,registrationNumber){
  requireCampus();const cls=check(await supabase.from('classes').select('id,code').eq('code',code.trim().toUpperCase()).eq('is_archived',false).single());
  const existing=check(await supabase.from('class_memberships').select('id,status').eq('class_id',cls.id).eq('student_id',user.id).maybeSingle());
  if(existing){if(existing.status==='active')throw new Error('You already belong to that class.');if(existing.status==='pending')throw new Error('Your request is already waiting for teacher approval.');}
  return check(await supabase.from('class_memberships').insert({class_id:cls.id,student_id:user.id,registration_number:registrationNumber||null,status:'pending'}).select().single());
}
export async function createClass(user,fields){
  requireCampus();
  return check(await supabase.rpc('create_campus_class',{p_class_data:{...fields,code:fields.code.trim().toUpperCase()},p_subject_ids:fields.subject_ids||[]}));
}
export async function listBranches(){requireCampus();return check(await supabase.from('branches').select('id,name,code,description').eq('is_active',true).order('name'))}
export async function listSubjects(branchId){requireCampus();let q=supabase.from('subjects').select('id,branch_id,name,code').order('name');if(branchId)q=q.eq('branch_id',branchId);return check(await q)}
export async function loadClassSubjects(classId){requireCampus();return check(await supabase.from('class_subjects').select('id,subject:subjects(id,name,code),branch:branches(name,code)').eq('class_id',classId))}
export async function saveClassRoutine(user,fields){requireCampus();return check(await supabase.from('class_routines').insert({...fields,teacher_id:user.id,created_by:user.id}).select().single())}
export async function loadTeacherAssignments(){
  requireCampus();
  const rows=check(await supabase.from('branch_teachers').select('branch_id,subject_id,teacher_id,created_at').order('created_at',{ascending:false}));
  if(!rows.length)return [];
  const branchIds=[...new Set(rows.map(x=>x.branch_id))],subjectIds=[...new Set(rows.map(x=>x.subject_id))],teacherIds=[...new Set(rows.map(x=>x.teacher_id))];
  const [branches,subjects,teachers]=await Promise.all([
    supabase.from('branches').select('id,name,code').in('id',branchIds),
    supabase.from('subjects').select('id,branch_id,name,code').in('id',subjectIds),
    supabase.from('profiles').select('id,full_name,email').in('id',teacherIds),
  ]);
  for(const result of [branches,subjects,teachers])if(result.error)throw result.error;
  const byBranch=new Map((branches.data||[]).map(x=>[x.id,x])),bySubject=new Map((subjects.data||[]).map(x=>[x.id,x])),byTeacher=new Map((teachers.data||[]).map(x=>[x.id,x]));
  return rows.map(x=>({...x,branch:byBranch.get(x.branch_id),subject:bySubject.get(x.subject_id),teacher:byTeacher.get(x.teacher_id)}));
}
export async function loadTeacherBranchSubjects(user){requireCampus();return check(await supabase.from('branch_teachers').select('branch_id,subject_id,branch:branches!branch_teachers_branch_id_fkey(id,name,code,campus_id),subject:subjects!branch_teachers_branch_id_subject_id_fkey(id,name,code)').eq('teacher_id',user.id))}
export async function getAdminCampus(){requireCampus();const {data,error}=await supabase.from('campus_admins').select('campus_id,campus:campuses(id,name,campus_code)').eq('user_id',(await supabase.auth.getUser()).data.user.id).limit(1).maybeSingle();if(error)throw error;if(!data)throw new Error('Your account has not been assigned to a campus yet.');return data.campus}
export async function createBranch(user,fields){requireCampus();const campus=await getAdminCampus();return check(await supabase.from('branches').insert({...fields,campus_id:campus.id,code:fields.code.trim().toUpperCase(),created_by:user.id}).select().single())}
export async function createAcademicSession(fields){requireCampus();const campus=await getAdminCampus();return check(await supabase.from('academic_sessions').insert({...fields,campus_id:campus.id}).select().single())}
export async function linkBranchToSession(user,sessionId,branchId){requireCampus();const campus=await getAdminCampus();return check(await supabase.from('session_branches').insert({campus_id:campus.id,session_id:sessionId,branch_id:branchId,created_by:user.id}).select().single())}
export async function listSessionBranchLinks(){requireCampus();return check(await supabase.from('session_branches').select('session_id,branch_id,session:academic_sessions(id,name,is_active),branch:branches(id,name,code,is_active)').order('created_at'))}
export async function createSubject(fields){requireCampus();return check(await supabase.from('subjects').insert({...fields,code:fields.code.trim().toUpperCase()}).select().single())}
export async function syncBranchTeachersToClasses(adminId,{branch_id,subject_ids,class_ids}){
  requireCampus();
  let q=supabase.from('class_subjects').select('class_id,branch_id,subject_id').eq('branch_id',branch_id);
  if(class_ids?.length)q=q.in('class_id',class_ids);
  const classLinks=check(await q);
  if(!classLinks.length)return 0;
  const assignments=check(await supabase.from('branch_teachers').select('branch_id,subject_id,teacher_id').eq('branch_id',branch_id).in('subject_id',subject_ids));
  if(!assignments.length)return 0;
  const allSubjectIds=[...new Set([...classLinks.map(x=>x.subject_id),...assignments.map(x=>x.subject_id)])];
  const subjects=check(await supabase.from('subjects').select('id,branch_id,code,name').eq('branch_id',branch_id).in('id',allSubjectIds));
  const subjectKey=new Map(subjects.map(s=>[s.id,`${s.branch_id}:${String(s.code||s.name).trim().toLowerCase()}`]));
  const bySubject=new Map();for(const row of assignments){const key=subjectKey.get(row.subject_id)||`${row.branch_id}:${row.subject_id}`;const list=bySubject.get(key)||[];list.push(row.teacher_id);bySubject.set(key,list)}
  const rows=[...new Map(classLinks.flatMap(link=>(bySubject.get(subjectKey.get(link.subject_id)||`${link.branch_id}:${link.subject_id}`)||[]).map(teacher_id=>[`${link.class_id}:${teacher_id}`,{class_id:link.class_id,teacher_id,added_by:adminId}]))).values()];
  if(rows.length)check(await supabase.from('class_teachers').upsert(rows,{onConflict:'class_id,teacher_id',ignoreDuplicates:true}));
  return rows.length;
}
export async function syncAllBranchTeachersToClasses(adminId){
  requireCampus();
  const [assignments,classLinks]=await Promise.all([supabase.from('branch_teachers').select('branch_id,subject_id,teacher_id'),supabase.from('class_subjects').select('class_id,branch_id,subject_id')]);
  if(assignments.error)throw assignments.error;if(classLinks.error)throw classLinks.error;
  const allRows=[...(assignments.data||[]),...(classLinks.data||[])];
  if(!allRows.length)return 0;
  const subjectIds=[...new Set(allRows.map(x=>x.subject_id).filter(Boolean))];
  const {data:subjects,error:subjectError}=await supabase.from('subjects').select('id,branch_id,code,name').in('id',subjectIds);
  if(subjectError)throw subjectError;
  const subjectKey=new Map((subjects||[]).map(s=>[s.id,`${s.branch_id}:${String(s.code||s.name).trim().toLowerCase()}`]));
  const assigned=new Map();for(const row of assignments.data||[]){const key=subjectKey.get(row.subject_id)||`${row.branch_id}:${row.subject_id}`,list=assigned.get(key)||[];list.push(row.teacher_id);assigned.set(key,list)}
  const rows=[...new Map((classLinks.data||[]).flatMap(link=>(assigned.get(subjectKey.get(link.subject_id)||`${link.branch_id}:${link.subject_id}`)||[]).map(teacher_id=>[`${link.class_id}:${teacher_id}`,{class_id:link.class_id,teacher_id,added_by:adminId}]))).values()];
  if(rows.length)check(await supabase.from('class_teachers').upsert(rows,{onConflict:'class_id,teacher_id',ignoreDuplicates:true}));
  return rows.length;
}
export async function assignBranchTeacher(user,{branch_id,subject_id,teacher_id}){requireCampus();check(await supabase.from('branch_teachers').upsert({branch_id,subject_id,teacher_id,assigned_by:user.id},{onConflict:'branch_id,subject_id,teacher_id',ignoreDuplicates:true}));return syncBranchTeachersToClasses(user.id,{branch_id,subject_ids:[subject_id]})}
export async function unassignBranchTeacher({branch_id,subject_id,teacher_id}){
  requireCampus();
  const links=check(await supabase.from('class_subjects').select('class_id').eq('branch_id',branch_id).eq('subject_id',subject_id));
  const removed=check(await supabase.from('branch_teachers').delete().eq('branch_id',branch_id).eq('subject_id',subject_id).eq('teacher_id',teacher_id).select().maybeSingle());
  const classIds=[...new Set(links.map(x=>x.class_id))];
  if(classIds.length){
    const [classSubjects,remaining]=await Promise.all([supabase.from('class_subjects').select('class_id,branch_id,subject_id').in('class_id',classIds),supabase.from('branch_teachers').select('branch_id,subject_id').eq('teacher_id',teacher_id)]);
    if(classSubjects.error)throw classSubjects.error;if(remaining.error)throw remaining.error;
    const pairs=new Set((remaining.data||[]).map(x=>`${x.branch_id}:${x.subject_id}`));
    const stillAssigned=new Set((classSubjects.data||[]).filter(x=>pairs.has(`${x.branch_id}:${x.subject_id}`)).map(x=>x.class_id));
    const revoke=classIds.filter(id=>!stillAssigned.has(id));
    if(revoke.length)check(await supabase.from('class_teachers').delete().eq('teacher_id',teacher_id).in('class_id',revoke));
  }
  return removed;
}
export async function loadClassTeacherAssignments(classIds){requireCampus();if(!classIds.length)return [];return check(await supabase.from('class_teachers').select('class_id,teacher_id').in('class_id',classIds))}
export async function assignTeacherToClass(classId,teacherId,adminId){requireCampus();return check(await supabase.from('class_teachers').insert({class_id:classId,teacher_id:teacherId,added_by:adminId}).select().single())}
export async function assignTeacherToClassSubject({classId,branchId,subjectId,teacherId,adminId}){
  requireCampus();
  check(await supabase.from('class_subjects').upsert({class_id:classId,branch_id:branchId,subject_id:subjectId},{onConflict:'class_id,subject_id',ignoreDuplicates:true}));
  check(await supabase.from('branch_teachers').upsert({branch_id:branchId,subject_id:subjectId,teacher_id:teacherId,assigned_by:adminId},{onConflict:'branch_id,subject_id,teacher_id',ignoreDuplicates:true}));
  check(await supabase.from('class_teachers').upsert({class_id:classId,teacher_id:teacherId,added_by:adminId},{onConflict:'class_id,teacher_id',ignoreDuplicates:true}));
  return true;
}
export async function unassignTeacherFromClass(classId,teacherId){requireCampus();return check(await supabase.from('class_teachers').delete().eq('class_id',classId).eq('teacher_id',teacherId).select().maybeSingle())}
async function resolveClassSubject(user,classId,requested){if(requested)return requested;const links=check(await supabase.from('class_subjects').select('id,subject_id').eq('class_id',classId));if(!links.length)throw new Error('This class has no subject assigned yet.');const assignments=check(await supabase.from('branch_teachers').select('subject_id').eq('teacher_id',user.id).in('subject_id',links.map(x=>x.subject_id)));const allowed=new Set(assignments.map(x=>x.subject_id));const link=links.find(x=>allowed.has(x.subject_id));if(!link)throw new Error('You are not assigned to a subject in this class.');return link.id}
export async function loadClassRoster(classId){requireCampus();const [roster,classResult]=await Promise.all([supabase.from('class_memberships').select('student_id,registration_number,student:profiles!class_memberships_student_id_fkey(id,full_name,campus_id,email)').eq('class_id',classId).eq('status','active'),supabase.from('classes').select('branch:branches(campus_id)').eq('id',classId).single()]);if(roster.error)throw roster.error;if(classResult.error)throw classResult.error;const rows=roster.data||[];if(!rows.length)return [];const {data:enrollments,error}=await supabase.from('campus_enrollments').select('user_id,student_code,college_registration_number').eq('campus_id',classResult.data.branch?.campus_id).in('user_id',rows.map(x=>x.student_id));if(error)throw error;const codes=new Map((enrollments||[]).map(x=>[x.user_id,x]));return rows.map(x=>({...x,registration_number:codes.get(x.student_id)?.college_registration_number||x.registration_number||codes.get(x.student_id)?.student_code||x.student?.campus_id||null})).sort((a,b)=>{const left=a.registration_number||'',right=b.registration_number||'';if(!left)return right?1:(a.student?.full_name||'').localeCompare(b.student?.full_name||'');if(!right)return -1;return left.localeCompare(right,undefined,{numeric:true,sensitivity:'base'})})}
export async function loadSessionAttendance(classId,date){requireCampus();const sessionResult=await supabase.from('attendance_sessions').select('id,state,note').eq('class_id',classId).eq('session_date',date).maybeSingle();const session=check(sessionResult);if(!session)return {session:null,records:[]};const records=check(await supabase.from('attendance_records').select('student_id,status').eq('session_id',session.id));return {session,records}}
export async function saveClassAttendance({classId,date,teacherId,rows,suspended,note}){
  requireCampus();const session=check(await supabase.from('attendance_sessions').upsert({class_id:classId,session_date:date,state:suspended?'suspended':'held',note:note||null,recorded_by:teacherId,recorded_at:new Date().toISOString()},{onConflict:'class_id,session_date'}).select('id').single());
  if(suspended)return session;
  const records=rows.map(r=>({session_id:session.id,student_id:r.student_id,status:r.status,marked_by:teacherId}));
  if(records.length)check(await supabase.from('attendance_records').upsert(records,{onConflict:'session_id,student_id'}));return session;
}
export async function loadStudentAttendance(studentId){requireCampus();return check(await supabase.from('attendance_records').select('status,session:attendance_sessions(session_date,class:classes(code,name))').eq('student_id',studentId).order('created_at',{ascending:false}).limit(100))}
export async function loadStudentAssignments(classIds){requireCampus();if(!classIds.length)return [];return check(await supabase.from('assignments').select('id,class_id,title,description,due_at,max_score,attachment_path,resource_url,mime_type,file_size,class:classes(name,code),submissions(id,submitted_at,score,teacher_feedback)').in('class_id',classIds).order('due_at',{ascending:true}))}
export async function loadClassMaterials(classIds){requireCampus();if(!classIds.length)return [];return check(await supabase.from('materials').select('id,class_id,title,description,storage_path,resource_url,mime_type,file_size,created_at,class:classes(name,code)').in('class_id',classIds).order('created_at',{ascending:false}))}
export async function downloadMaterial(path){requireCampus();const result=await supabase.storage.from('class-materials').createSignedUrl(path,90);return check(result).signedUrl}
export async function loadTeacherStudents(classId){return loadClassRoster(classId)}
export async function approveTeacher(id,approved){requireCampus();const profile=check(await supabase.from('profiles').update({account_status:approved?'active':'suspended'}).eq('id',id).select().single());const {data,error}=await supabase.from('campus_enrollments').select('id').eq('user_id',id).eq('status','pending').maybeSingle();if(error)throw error;if(data){const result=await supabase.rpc('review_campus_enrollment',{target_enrollment:data.id,approve});if(result.error)throw result.error}return profile}
export async function reviewMembership(classId,studentId,reviewedBy,approved){requireCampus();return check(await supabase.from('class_memberships').update({status:approved?'active':'rejected',reviewed_by:reviewedBy,reviewed_at:new Date().toISOString()}).eq('class_id',classId).eq('student_id',studentId).select().single())}
async function uploadClassAttachment(classId,classSubjectId,file){validateCampusFile(file);if(!file)return {path:null,mime:null,size:null};const safe=file.name.replace(/[^a-zA-Z0-9._-]/g,'_'),path=`${classId}/${classSubjectId}/${crypto.randomUUID()}-${safe}`;check(await supabase.storage.from('class-materials').upload(path,file,{contentType:file.type||'application/octet-stream',upsert:false}));return {path,mime:file.type||null,size:file.size}}
export async function createAssignment(user,fields){requireCampus();const class_subject_id=await resolveClassSubject(user,fields.class_id,fields.class_subject_id),resource_url=cleanResourceUrl(fields.resource_url);let upload={path:null,mime:null,size:null};try{upload=await uploadClassAttachment(fields.class_id,class_subject_id,fields.file);const {file,...values}=fields;return check(await supabase.from('assignments').insert({...values,class_subject_id,resource_url,attachment_path:upload.path,mime_type:upload.mime,file_size:upload.size,created_by:user.id}).select().single())}catch(error){if(upload.path)await supabase.storage.from('class-materials').remove([upload.path]);throw error}}
export async function createSyllabusUnit(user,fields){requireCampus();const class_subject_id=await resolveClassSubject(user,fields.class_id,fields.class_subject_id),resource_url=cleanResourceUrl(fields.resource_url);let upload={path:null,mime:null,size:null};try{upload=await uploadClassAttachment(fields.class_id,class_subject_id,fields.file);const {file,...values}=fields;return check(await supabase.from('syllabus_units').insert({...values,class_subject_id,resource_url,attachment_path:upload.path,mime_type:upload.mime,file_size:upload.size,created_by:user.id}).select().single())}catch(error){if(upload.path)await supabase.storage.from('class-materials').remove([upload.path]);throw error}}
export async function saveStudyProgress(unitId,studentId,isComplete){requireCampus();return check(await supabase.from('study_progress').upsert({unit_id:unitId,student_id:studentId,is_complete:isComplete,updated_at:new Date().toISOString()},{onConflict:'unit_id,student_id'}).select().single())}
export async function uploadClassMaterial(user,{classId,classSubjectId,title,description,content_text,file,resource_url}){
  requireCampus();resource_url=cleanResourceUrl(resource_url);if(!file&&!resource_url)throw new Error('Upload a PDF/CSV or add a resource link.');const class_subject_id=await resolveClassSubject(user,classId,classSubjectId);let upload={path:null,mime:null,size:null};
  try{upload=await uploadClassAttachment(classId,class_subject_id,file);return check(await supabase.from('materials').insert({class_id:classId,class_subject_id,title,description,content_text:content_text||null,storage_path:upload.path,resource_url,mime_type:upload.mime,file_size:upload.size,uploaded_by:user.id}).select().single())}
  catch(error){if(upload.path)await supabase.storage.from('class-materials').remove([upload.path]);throw error}
}
export async function publishNotice(user,fields){requireCampus();const {audience,class_id,title,body}=fields;let campus_id;if(class_id){const cls=check(await supabase.from('classes').select('branch:branches(campus_id)').eq('id',class_id).single());campus_id=cls.branch?.campus_id}else campus_id=check(await supabase.rpc('my_campus_id'));if(!campus_id)throw new Error('Your account is not linked to a campus.');return check(await supabase.from('notices').insert({title,body,campus_id,audience_role:audience==='campus'?null:audience==='teachers'?'teacher':audience==='students'?'student':null,class_id:class_id||null,created_by:user.id}).select().single())}
export async function submitReview(user,{classId,subjectId,rating,body,reviewMonth,reviewerRole='student'}){requireCampus();return check(await supabase.from('reviews').upsert({class_id:classId,reviewer_id:user.id,subject_id:subjectId,reviewer_role:reviewerRole,rating:Number(rating),body,review_month:reviewMonth||new Date().toISOString().slice(0,7)+'-01'},{onConflict:'class_id,reviewer_id,subject_id,review_month'}).select().single())}
export async function loadPendingTeachers(){requireCampus();const campus=await getAdminCampus();const rows=check(await supabase.from('campus_enrollments').select('status,teacher:profiles!campus_enrollments_user_id_fkey(id,role,full_name,email,mobile,department,created_at,account_status)').eq('campus_id',campus.id).eq('status','pending').order('requested_at'));return rows.map(x=>x.teacher).filter(x=>x?.role==='teacher'&&x.account_status==='pending')}
export async function listProfiles(role){requireCampus();let query=supabase.from('profiles').select('id,full_name,email,mobile,gender,campus_id,department,account_status,created_at,guardian_name,guardian_mobile,emergency_contact_name,emergency_contact_mobile').order('full_name');if(role)query=query.eq('role',role);return check(await query)}
export async function saveSubmission(user,assignmentId,file){
  requireCampus();if(!file)throw new Error('Choose the assignment file first.');validateCampusFile(file);const path=`${assignmentId}/${user.id}/${crypto.randomUUID()}-${file.name.replace(/[^a-zA-Z0-9._-]/g,'_')}`;
  check(await supabase.storage.from('assignment-submissions').upload(path,file,{contentType:file.type||'application/octet-stream'}));
  try{return check(await supabase.from('submissions').upsert({assignment_id:assignmentId,student_id:user.id,storage_path:path,submitted_at:new Date().toISOString()},{onConflict:'assignment_id,student_id'}).select().single())}
  catch(error){await supabase.storage.from('assignment-submissions').remove([path]);throw error}
}
