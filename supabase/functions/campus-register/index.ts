import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
});
const signupWindows = new Map<string, { startedAt: number; count: number }>();
function registrationRateLimited(req: Request) {
  const forwarded = req.headers.get('cf-connecting-ip') || req.headers.get('x-real-ip') || req.headers.get('x-forwarded-for')?.split(',')[0]?.trim();
  const key = forwarded || 'unknown-client';
  const now = Date.now();
  let window = signupWindows.get(key);
  const windowMs = 15 * 60_000;
  if (!window || now - window.startedAt >= windowMs) {
    if (!window && signupWindows.size >= 10_000) {
      for (const [candidate, item] of signupWindows) if (now - item.startedAt >= windowMs) signupWindows.delete(candidate);
      if (signupWindows.size >= 10_000) return true;
    }
    window = { startedAt: now, count: 0 };
    signupWindows.set(key, window);
  }
  if (window.count >= 5) return true;
  window.count++;
  return false;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Use POST to register a campus account.' }, 405);
  if (registrationRateLimited(req)) return json({ error: 'Too many account requests from this network. Please wait 15 minutes and try again.' }, 429);

  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !serviceKey) return json({ error: 'Campus registration is not configured on the server.' }, 503);

  try {
    const body = await req.json();
    const role = body.role;
    const email = String(body.email || '').trim().toLowerCase();
    const password = String(body.password || '');
    const fullName = String(body.full_name || '').trim();
    const campusCode = String(body.campus_code || '').trim().toUpperCase();
    const collegeRegistrationNumber = String(body.college_registration_number || '').trim().toUpperCase();
    if (!['teacher', 'student'].includes(role)) return json({ error: 'Only teacher and student accounts use this registration route.' }, 400);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254 || password.length < 8 || password.length > 128 || !fullName || fullName.length > 120 || !campusCode || campusCode.length > 32) return json({ error: 'Enter a valid email, a password of 8–128 characters, a name up to 120 characters, and a Campus ID.' }, 400);
    if (role === 'student' && (collegeRegistrationNumber.length < 2 || collegeRegistrationNumber.length > 80)) return json({ error: 'Enter the registration number issued to you by your college (2–80 characters).' }, 400);
    for (const field of ['mobile','gender','department','address','guardian_name','guardian_mobile','emergency_contact_name','emergency_contact_mobile']) {
      if (body[field] != null && String(body[field]).length > 240) return json({ error: 'One of the optional profile fields is too long.' }, 400);
    }

    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: campus, error: campusError } = await admin.from('campuses')
      .select('id,campus_code').eq('campus_code', campusCode).eq('is_active', true).maybeSingle();
    if (campusError) throw campusError;
    if (!campus) return json({ error: 'Campus ID not found or inactive. Check with your campus admin.' }, 404);

    if (role === 'student') {
      const { data: duplicate, error: duplicateError } = await admin.from('campus_enrollments')
        .select('id').eq('campus_id', campus.id).eq('college_registration_number', collegeRegistrationNumber).maybeSingle();
      if (duplicateError) throw duplicateError;
      if (duplicate) return json({ error: 'This college registration number is already registered in this campus. Check the number or contact your campus admin.' }, 409);
    }

    const branchId = body.branch_id ? String(body.branch_id) : null;
    const sessionId = body.session_id ? String(body.session_id) : null;
    if (role === 'student') {
      if (!branchId || !sessionId) return json({ error: 'Choose a branch and academic session.' }, 400);
      const [branchResult, sessionResult] = await Promise.all([
        admin.from('branches').select('id').eq('id', branchId).eq('campus_id', campus.id).eq('is_active', true).maybeSingle(),
        admin.from('academic_sessions').select('id').eq('id', sessionId).eq('campus_id', campus.id).eq('is_active', true).maybeSingle(),
      ]);
      if (branchResult.error) throw branchResult.error;
      if (sessionResult.error) throw sessionResult.error;
      if (!branchResult.data || !sessionResult.data) return json({ error: 'Selected branch or academic session does not belong to this campus.' }, 400);
      const { data: sessionBranch, error: pairError } = await admin.from('session_branches')
        .select('branch_id').eq('campus_id', campus.id).eq('branch_id', branchId).eq('session_id', sessionId).maybeSingle();
      if (pairError) throw pairError;
      if (!sessionBranch) return json({ error: 'That branch is not offered in the selected academic session. Choose a matching session and branch.' }, 400);
    }

    const { data, error } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        requested_role: role,
        full_name: fullName,
        mobile: body.mobile || null,
        gender: body.gender || null,
        campus_code: campus.campus_code,
        branch_id: branchId,
        session_id: sessionId,
        college_registration_number: role === 'student' ? collegeRegistrationNumber : null,
        department: body.department || null,
        address: body.address || null,
        guardian_name: body.guardian_name || null,
        guardian_mobile: body.guardian_mobile || null,
        emergency_contact_name: body.emergency_contact_name || null,
        emergency_contact_mobile: body.emergency_contact_mobile || null,
      },
    });
    if (error) return json({ error: error.message }, 400);
    if (role === 'teacher') {
      // Keep the campus approval queue reliable even if the Auth enrollment
      // trigger was missed during an earlier partial schema setup.
      const { error: enrollmentError } = await admin.from('campus_enrollments').upsert({
        campus_id: campus.id,
        user_id: data.user.id,
        status: 'pending',
      }, { onConflict: 'campus_id,user_id', ignoreDuplicates: true });
      if (enrollmentError) {
        await admin.auth.admin.deleteUser(data.user.id);
        throw enrollmentError;
      }
    } else {
      const { data: enrollment, error: registrationError } = await admin.from('campus_enrollments')
        .update({ college_registration_number: collegeRegistrationNumber })
        .eq('campus_id', campus.id).eq('user_id', data.user.id).select('id').maybeSingle();
      if (registrationError || !enrollment) {
        await admin.auth.admin.deleteUser(data.user.id);
        if (registrationError?.code === '23505') return json({ error: 'This college registration number is already registered in this campus.' }, 409);
        throw registrationError || new Error('Could not save your college registration number.');
      }
    }
    return json({ ok: true, role, user_id: data.user.id, message: role === 'teacher'
      ? 'Account created. The campus admin must approve the teacher account.'
      : 'Account created. The teacher must approve your campus enrollment.' });
  } catch (err) {
    return json({ error: err instanceof Error ? err.message : 'Could not create this account.' }, 500);
  }
});
