/// Puffle build-time configuration. Nothing secret lives here: the Supabase URL and
/// publishable key are public by design (access is enforced by RLS on the server).
class Config {
  static const appName = 'Puffle';
  static const shortCode = 'PF';
  static const websiteUrl = String.fromEnvironment('WEBSITE_URL', defaultValue: 'https://puffle-iota.vercel.app');
  static const supportEmail = String.fromEnvironment('SUPPORT_EMAIL', defaultValue: 'help.puffle@gmail.com');
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://dqufassvbkattmmsuwmf.supabase.co');
  static const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY', defaultValue: 'sb_publishable_V1Mz2QEjH6Xh2ydtPFEChw_9akgiOZE');

  /// Set by CI for the Play bundle: no UPI, no WebView, no prices.
  static const playStore = bool.fromEnvironment('PLAY_STORE');

  /// Set by CI for the ads APK: utm_source=meta&utm_medium=paid_social&utm_campaign=apk_download
  static const apkReferrer = String.fromEnvironment('APK_REFERRER');
  static const authScheme = String.fromEnvironment('AUTH_SCHEME', defaultValue: 'com.pufflecloud.app');

  /// Kept in sync with pubspec.yaml; a test fails when they differ.
  static const versionLabel = '1.0.5';
}
