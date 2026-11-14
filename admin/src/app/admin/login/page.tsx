"use client";
import { Suspense, useState } from "react";
import { useSearchParams } from "next/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

function LoginForm() {
  const q = useSearchParams();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [err, setErr] = useState(q.get("error") ?? "");
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr("");
    const sb = supabaseBrowser();
    const { error } = await sb.auth.signInWithPassword({ email: email.trim(), password });
    if (error) { setBusy(false); return setErr(error.message === "Invalid login credentials" ? "Wrong email or password." : error.message); }
    const { data: isAdmin } = await sb.rpc("is_admin");
    if (!isAdmin) { await sb.auth.signOut(); setBusy(false); return setErr("This account is not an admin."); }
    window.location.href = "/admin";
  }

  const input = "w-full rounded-xl border border-slate-300 bg-white px-3 py-3 text-sm text-gray-900 focus:border-teal-600 focus:outline-none focus:ring-1 focus:ring-teal-600";
  return (
    <form onSubmit={submit} className="w-full max-w-md space-y-5 rounded-2xl border border-slate-200 bg-white p-7 shadow-sm sm:p-9">
      <div className="flex items-center gap-3">
        <div className="grid h-10 w-10 place-items-center rounded-lg bg-teal-700 font-bold text-white">PF</div>
        <div>
          <div className="font-semibold text-gray-900">Puffle Admin</div>
          <div className="text-xs text-gray-500">Sign in with your admin account</div>
        </div>
      </div>
      <label className="block text-sm"><span className="mb-1 block font-medium text-gray-700">Email</span>
        <input className={input} type="email" value={email} onChange={(e) => setEmail(e.target.value)} required autoComplete="email" />
      </label>
      <label className="block text-sm"><span className="mb-1 block font-medium text-gray-700">Password</span>
        <input className={input} type="password" value={password} onChange={(e) => setPassword(e.target.value)} required autoComplete="current-password" />
      </label>
      {err && <p className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700" role="alert">{err}</p>}
      <button className="w-full rounded-lg bg-teal-700 px-4 py-3 text-sm font-semibold text-white hover:bg-teal-800 disabled:opacity-50" disabled={busy}>{busy ? "Signing in…" : "Sign in"}</button>
    </form>
  );
}

export default function Login() {
  return (
    <main className="admin-login grid min-h-screen lg:grid-cols-2">
      <section className="admin-welcome hidden flex-col justify-between p-12 text-white lg:flex xl:p-20">
        <div className="text-2xl font-semibold tracking-tight">Puffle<span className="ml-3 text-xs font-normal tracking-wide text-teal-200">ADMIN WORKSPACE</span></div>
        <div><p className="text-xs font-semibold uppercase tracking-[.2em] text-teal-200">CONTENT. COMMUNITY. GROWTH.</p><h1 className="mt-5 max-w-lg text-5xl font-semibold leading-tight tracking-tight">One workspace.<br />Every channel.</h1><p className="mt-6 max-w-md text-base leading-relaxed text-slate-300">Manage your content library, review new channels and bring the right videos to the right audience.</p><div className="mt-10 flex flex-wrap gap-3 text-xs text-teal-100"><span className="rounded-full border border-white/20 px-4 py-2">Channel approvals</span><span className="rounded-full border border-white/20 px-4 py-2">Bulk uploads</span><span className="rounded-full border border-white/20 px-4 py-2">Audience controls</span></div></div>
        <p className="text-xs text-slate-400">Puffle · Content & community management</p>
      </section>
      <section className="flex min-h-screen items-center justify-center px-5 py-12"><Suspense fallback={null}><LoginForm /></Suspense></section>
    </main>
  );
}
