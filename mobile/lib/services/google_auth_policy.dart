/// Linking preserves a guest's ID and its purchases instead of signing into a different account.
bool shouldLinkGoogleIdentity({required bool anonymous, required bool signup, required bool saveMode, required bool premium}) =>
    anonymous && (signup || saveMode || premium);
