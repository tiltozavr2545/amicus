// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get unexpectedError => 'Unexpected error. Please try again.';

  @override
  String get cancelButton => 'Cancel';

  @override
  String get deleteButton => 'Delete';

  @override
  String get saveButton => 'Save';

  @override
  String get nameLabel => 'Name';

  @override
  String get passwordLabel => 'Password';

  @override
  String get nameRequiredError => 'Enter your name';

  @override
  String get invalidCredentialsError => 'Incorrect email or password.';

  @override
  String get emailNotConfirmedError =>
      'Please confirm your email before signing in.';

  @override
  String get weakPasswordError =>
      'This password is too weak. Try a longer one.';

  @override
  String get authRateLimitedError =>
      'Too many attempts. Please wait a bit and try again.';

  @override
  String get accountDisabledError => 'This account has been disabled.';

  @override
  String get signUpTitle => 'Sign up';

  @override
  String get signUpButton => 'Sign up';

  @override
  String get goToSignInButton => 'Go to sign in';

  @override
  String get alreadyHaveAccountButton => 'Already have an account? Sign in';

  @override
  String get emailAlreadyRegisteredError =>
      'This email is already registered. Try signing in.';

  @override
  String confirmationEmailSentMessage(String email) {
    return 'A confirmation link has been sent to $email. Follow the link in the email, then come back and sign in with this email and password.';
  }

  @override
  String get signInTitle => 'Sign in';

  @override
  String get signInButton => 'Sign in';

  @override
  String get noAccountSignUpButton => 'No account? Sign up';

  @override
  String get forgotPasswordButton => 'Forgot password?';

  @override
  String get resetPasswordTitle => 'Reset password';

  @override
  String get resetPasswordInstructions =>
      'Enter the email linked to your account — we\'ll send you a reset link.';

  @override
  String resetPasswordSuccessMessage(String email) {
    return 'If an account with the email $email exists, we\'ve sent a link to reset the password.';
  }

  @override
  String get sendLinkButton => 'Send link';

  @override
  String get backToSignInButton => 'Back to sign in';

  @override
  String get feedTabLabel => 'Feed';

  @override
  String get connectionsTitle => 'Connections';

  @override
  String get newPostTitle => 'New post';

  @override
  String get profileTitle => 'Profile';

  @override
  String get inviteSectionTitle => 'Invite';

  @override
  String get copyTooltip => 'Copy';

  @override
  String get codeCopiedMessage => 'Code copied';

  @override
  String get createInviteCodeButton => 'Create invite code';

  @override
  String get createNewCodeButton => 'Create new code';

  @override
  String get haveCodeSectionTitle => 'I have a code';

  @override
  String get inviteCodeLabel => 'Invite code';

  @override
  String get inviteCodeRequiredError => 'Enter an invite code';

  @override
  String get inviteCodeNotFoundError =>
      'Invite code not found. Check it and try again.';

  @override
  String get inviteCodeAlreadyUsedError =>
      'This invite code has already been used.';

  @override
  String get ownInviteCodeError =>
      'That\'s your own invite code — share it with someone else.';

  @override
  String get activateButton => 'Activate';

  @override
  String get myConnectionsTitle => 'My connections';

  @override
  String get failedToLoadConnectionsError =>
      'Failed to load list. Please try again.';

  @override
  String get noConnectionsYetMessage =>
      'No connections yet — activate a code or create one above';

  @override
  String nowConnectedWithMessage(String name) {
    return 'You\'re now connected with $name';
  }

  @override
  String get favoriteFriendTooltip => 'Add to favorites';

  @override
  String get unfavoriteFriendTooltip => 'Remove from favorites';

  @override
  String get muteFriendTooltip => 'Mute';

  @override
  String get unmuteFriendTooltip => 'Unmute';

  @override
  String muteFriendTitle(String name) {
    return 'Mute $name?';
  }

  @override
  String get muteFriendContent =>
      'You won\'t see their posts in your feed. You\'ll still be connected.';

  @override
  String get muteButton => 'Mute';

  @override
  String get blockFriendTooltip => 'Block';

  @override
  String blockFriendTitle(String name) {
    return 'Block $name?';
  }

  @override
  String get blockFriendContent =>
      'Neither of you will see each other\'s posts. You\'ll still be connected.';

  @override
  String get blockButton => 'Block';

  @override
  String get unblockButton => 'Unblock';

  @override
  String get blockedUsersTooltip => 'Blocked users';

  @override
  String get blockedUsersTitle => 'Blocked';

  @override
  String get noBlockedUsersMessage => 'You haven\'t blocked anyone';

  @override
  String get publishButton => 'Publish';

  @override
  String get editPostTitle => 'Edit post';

  @override
  String get editButton => 'Edit';

  @override
  String get whatsNewHint => 'What\'s new?';

  @override
  String get addMediaButton => 'Add photo or video';

  @override
  String get removeMediaTooltip => 'Remove';

  @override
  String get playVideoTooltip => 'Play video';

  @override
  String get mediaLimitMessage => 'You can add up to 20 photos or videos';

  @override
  String get videoTooLongError => 'Video must be under 60 seconds';

  @override
  String get failedToAddMediaError => 'Some files couldn\'t be added';

  @override
  String get addTextOrPhotoError => 'Add text, a photo, or a video';

  @override
  String get failedToPublishError => 'Failed to publish. Please try again.';

  @override
  String get failedToSaveChangesError =>
      'Failed to save changes. Please try again.';

  @override
  String get deletePostTitle => 'Delete post?';

  @override
  String get deletePostContent =>
      'The post, its media, and comments will be deleted.';

  @override
  String get failedToLoadFeedError => 'Failed to load feed. Please try again.';

  @override
  String get failedToDeletePostError =>
      'Failed to delete post. Please try again.';

  @override
  String get noPostsYetMessage =>
      'No posts from connections yet. Add connections or write the first one.';

  @override
  String get addConnectionsButton => 'Add connections';

  @override
  String get myPostsTitle => 'My posts';

  @override
  String get noOwnPostsYetMessage => 'You haven\'t posted anything yet';

  @override
  String get postsTitle => 'Posts';

  @override
  String get noAuthorPostsYetMessage => 'This user hasn\'t posted anything yet';

  @override
  String get likeTooltip => 'Like';

  @override
  String get neutralTooltip => 'Neutral';

  @override
  String get dislikeTooltip => 'Dislike';

  @override
  String get darkThemeToggleTooltip => 'Toggle dark theme';

  @override
  String get failedToLoadProfileError =>
      'Failed to load profile. Please try again.';

  @override
  String get failedToSaveNameError => 'Failed to save name. Please try again.';

  @override
  String get addPhotoButton => 'Add photo';

  @override
  String get reorderPhotosButton => 'Reorder';

  @override
  String get deletePhotoButton => 'Delete photo';

  @override
  String get reorderPhotosTitle => 'Photo order';

  @override
  String get deletePhotosTitle => 'Delete photos';

  @override
  String get photoLimitMessage => 'You can add up to 80 photos';

  @override
  String get failedToLoadPhotosError =>
      'Failed to load photos. Please try again.';

  @override
  String get failedToAddPhotosError =>
      'Failed to add photos. Please try again.';

  @override
  String get failedToReorderPhotosError =>
      'Failed to reorder photos. Please try again.';

  @override
  String get failedToDeletePhotosError =>
      'Failed to delete photos. Please try again.';

  @override
  String get deletePhotosConfirmTitle => 'Delete selected photos?';

  @override
  String get deletePhotosConfirmContent =>
      'The selected photos will be permanently deleted.';

  @override
  String get commentsTitle => 'Comments';

  @override
  String get deleteCommentTitle => 'Delete comment?';

  @override
  String get noCommentsYetMessage => 'No comments yet';

  @override
  String get writeCommentHint => 'Write a comment...';

  @override
  String get writeReplyHint => 'Write a reply...';

  @override
  String get replyButton => 'Reply';

  @override
  String get cancelReplyTooltip => 'Cancel reply';

  @override
  String replyingToLabel(String name) {
    return 'Replying to: $name';
  }

  @override
  String inReplyToLabel(String name) {
    return 'In reply to: $name';
  }

  @override
  String get deletedCommentPlaceholder => 'Comment deleted';

  @override
  String get failedToLoadCommentsError =>
      'Failed to load comments. Please try again.';

  @override
  String get failedToDeleteCommentError =>
      'Failed to delete comment. Please try again.';

  @override
  String get failedToSendCommentError => 'Failed to send. Please try again.';

  @override
  String get connectionKnownLessThanDay => 'Known for less than a day';

  @override
  String connectionKnownDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days',
      one: '$days day',
    );
    return 'Known for $_temp0';
  }

  @override
  String connectionKnownMonths(int months) {
    String _temp0 = intl.Intl.pluralLogic(
      months,
      locale: localeName,
      other: '$months months',
      one: '$months month',
    );
    return 'Known for $_temp0';
  }

  @override
  String connectionKnownYears(int years) {
    String _temp0 = intl.Intl.pluralLogic(
      years,
      locale: localeName,
      other: '$years years',
      one: '$years year',
    );
    return 'Known for $_temp0';
  }

  @override
  String connectionSummary(String duration, String date) {
    return '$duration\nsince $date';
  }

  @override
  String get settingsTooltip => 'Settings';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get notificationsSectionTitle => 'Notifications';

  @override
  String get notifyAppUpdatesLabel => 'App update announcements';

  @override
  String get notifyFavoritesLabel => 'Posts from favorite friends';

  @override
  String get notifyCommentsLabel => 'Comments on your posts and replies to you';

  @override
  String get notifyDigestLabel => 'Digest of posts from everyone else';

  @override
  String get notifyInactiveLabel => 'Reminders after a quiet week';

  @override
  String get failedToLoadSettingsError =>
      'Failed to load settings. Please try again.';

  @override
  String get failedToSaveSettingsError => 'Failed to save. Please try again.';

  @override
  String appVersionLabel(String version, String build) {
    return 'Version $version ($build)';
  }

  @override
  String get languageSectionTitle => 'Language';

  @override
  String get languageSystemLabel => 'System default';

  @override
  String get accountSectionTitle => 'Account';

  @override
  String get signOutButton => 'Sign out';

  @override
  String get signOutDialogTitle => 'Sign out?';

  @override
  String get signOutDialogContent =>
      'You\'ll need to sign in again to use the app.';

  @override
  String get failedToSignOutError => 'Failed to sign out. Please try again.';

  @override
  String get deleteAccountLabel => 'Delete account';

  @override
  String get deleteAccountDialogTitle => 'Delete account?';

  @override
  String get deleteAccountDialogContent =>
      'This is permanent: your profile, posts, comments, and connections will all be deleted. This can\'t be undone.';

  @override
  String get failedToDeleteAccountError =>
      'Failed to delete account. Please try again.';
}
