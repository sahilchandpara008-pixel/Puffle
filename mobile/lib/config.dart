/// Puffle build-time configuration. Nothing secret lives here: the Supabase URL and
/// publishable key are public by design (access is enforced by RLS on the server).
class Config {
  static const appName = 'Puffle';
  static const shortCode = 'PF';
  static const websiteUrl = String.fromEnvironment('WEBSITE_URL', defaultValue: 'https://puffle-web.vercel.app');
  static const supportEmail = String.fromEnvironment('SUPPORT_EMAIL', defaultValue: 'help.puffle2026@gmail.com');
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://dqufassvbkattmmsuwmf.supabase.co');
  static const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY', defaultValue: 'sb_publishable_V1Mz2QEjH6Xh2ydtPFEChw_9akgiOZE');

  /// The standard Play bundle hides checkout. The plans build opts in explicitly.
  static const playStore = bool.fromEnvironment('PLAY_STORE') && !bool.fromEnvironment('PLAY_SELLS_UPI');

  /// Set by CI for the ads APK: utm_source=meta&utm_medium=paid_social&utm_campaign=apk_download
  static const apkReferrer = String.fromEnvironment('APK_REFERRER');
  static const authScheme = String.fromEnvironment('AUTH_SCHEME', defaultValue: 'com.pufflecloud.app');

  /// Puffle's Firebase project (puffle-c343d), used for push notifications.
  /// These are public client settings, not secrets.
  static const firebaseApiKey = 'AIzaSyBlILUSyztMiSBVSjauw-5VwCvC4jCQDtI';
  static const firebaseAppId = '1:749907003567:android:bca6deed3286cbfc56ac5a';
  static const firebaseSenderId = '749907003567';
  static const firebaseProjectId = 'puffle-c343d';

  /// Kept in sync with pubspec.yaml; a test fails when they differ.
  static const versionLabel = '1.0.24';
}
