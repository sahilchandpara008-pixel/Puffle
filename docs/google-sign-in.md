# Puffle Google sign-in activation

Use only the Puffle Google Cloud project and Supabase project dqufassvbkattmmsuwmf.

1. Create a Google Auth Platform OAuth client of type Web application. Brand the consent screen Puffle; use help.puffle2026@gmail.com and the Puffle privacy/terms URLs. Request only email/profile/openid sign-in access. Publish the OAuth audience when ready; testing mode only permits configured test users.
2. Authorised origin: https://puffle-iota.vercel.app
3. Authorised redirect URI: https://dqufassvbkattmmsuwmf.supabase.co/auth/v1/callback
4. Save the client ID and secret directly in Supabase Authentication → Sign In / Providers → Google, and enable Google. Never paste the secret in chat, source, or the APK.
5. In Supabase URL Configuration allow exactly com.pufflecloud.app://login-callback, retaining existing required reset-password callbacks. Keep the site URL https://puffle-iota.vercel.app.
6. Enable manual identity linking in Supabase Authentication settings for anonymous-to-Google upgrades. This does not grant access by itself; the user still authenticates with Google.

The app uses browser OAuth and its existing Android callback, without a native Google sign-in SDK. Guests saving a purchased plan, Premium guests, and guest sign-up use linkIdentity so the user ID and purchases stay attached. Ordinary returning-user login uses signInWithOAuth. An identity already linked to another account must not silently switch a paid guest or merge purchases; recover it through support. Existing email/password sign-in remains available.

Before declaring Google login active, test new Google sign-up, returning login, cancellation, denied/expired callbacks, and a paid guest linking Google (same user ID, same plan and source). Test both distribution APKs. Google authentication requires its own Google account chooser and permission screen; it is separate from optional advertising measurement consent.

Official setup: https://supabase.com/docs/guides/auth/social-sign-in/auth-google
Guest upgrade: https://supabase.com/docs/guides/auth/auth-anonymous
