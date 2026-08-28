import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// No description provided for @unexpectedError.
  ///
  /// In en, this message translates to:
  /// **'Unexpected error. Please try again.'**
  String get unexpectedError;

  /// No description provided for @cancelButton.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancelButton;

  /// No description provided for @deleteButton.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteButton;

  /// No description provided for @saveButton.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get saveButton;

  /// No description provided for @nameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get nameLabel;

  /// No description provided for @passwordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get passwordLabel;

  /// No description provided for @nameRequiredError.
  ///
  /// In en, this message translates to:
  /// **'Enter your name'**
  String get nameRequiredError;

  /// No description provided for @emailRequiredError.
  ///
  /// In en, this message translates to:
  /// **'Enter your email'**
  String get emailRequiredError;

  /// No description provided for @invalidEmailError.
  ///
  /// In en, this message translates to:
  /// **'Check the email address — it doesn\'t look right.'**
  String get invalidEmailError;

  /// No description provided for @undeliverableEmailError.
  ///
  /// In en, this message translates to:
  /// **'This domain can\'t receive mail. Enter a real email address.'**
  String get undeliverableEmailError;

  /// No description provided for @invalidCredentialsError.
  ///
  /// In en, this message translates to:
  /// **'Incorrect email or password.'**
  String get invalidCredentialsError;

  /// No description provided for @emailNotConfirmedError.
  ///
  /// In en, this message translates to:
  /// **'Please confirm your email before signing in.'**
  String get emailNotConfirmedError;

  /// No description provided for @weakPasswordError.
  ///
  /// In en, this message translates to:
  /// **'This password is too weak. Try a longer one.'**
  String get weakPasswordError;

  /// No description provided for @authRateLimitedError.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Please wait a bit and try again.'**
  String get authRateLimitedError;

  /// No description provided for @accountDisabledError.
  ///
  /// In en, this message translates to:
  /// **'This account has been disabled.'**
  String get accountDisabledError;

  /// No description provided for @signUpTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign up'**
  String get signUpTitle;

  /// No description provided for @signUpButton.
  ///
  /// In en, this message translates to:
  /// **'Sign up'**
  String get signUpButton;

  /// No description provided for @goToSignInButton.
  ///
  /// In en, this message translates to:
  /// **'Go to sign in'**
  String get goToSignInButton;

  /// No description provided for @alreadyHaveAccountButton.
  ///
  /// In en, this message translates to:
  /// **'Already have an account? Sign in'**
  String get alreadyHaveAccountButton;

  /// No description provided for @emailAlreadyRegisteredError.
  ///
  /// In en, this message translates to:
  /// **'This email is already registered. Try signing in.'**
  String get emailAlreadyRegisteredError;

  /// No description provided for @confirmationEmailSentMessage.
  ///
  /// In en, this message translates to:
  /// **'A confirmation link has been sent to {email}. Follow the link in the email, then come back and sign in with this email and password.'**
  String confirmationEmailSentMessage(String email);

  /// No description provided for @signInTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get signInTitle;

  /// No description provided for @signInButton.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get signInButton;

  /// No description provided for @noAccountSignUpButton.
  ///
  /// In en, this message translates to:
  /// **'No account? Sign up'**
  String get noAccountSignUpButton;

  /// No description provided for @forgotPasswordButton.
  ///
  /// In en, this message translates to:
  /// **'Forgot password?'**
  String get forgotPasswordButton;

  /// No description provided for @resetPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset password'**
  String get resetPasswordTitle;

  /// No description provided for @resetPasswordInstructions.
  ///
  /// In en, this message translates to:
  /// **'Enter the email linked to your account — we\'ll send you a reset link.'**
  String get resetPasswordInstructions;

  /// No description provided for @resetPasswordSuccessMessage.
  ///
  /// In en, this message translates to:
  /// **'If an account with the email {email} exists, we\'ve sent a link to reset the password.'**
  String resetPasswordSuccessMessage(String email);

  /// No description provided for @sendLinkButton.
  ///
  /// In en, this message translates to:
  /// **'Send link'**
  String get sendLinkButton;

  /// No description provided for @backToSignInButton.
  ///
  /// In en, this message translates to:
  /// **'Back to sign in'**
  String get backToSignInButton;

  /// No description provided for @feedTabLabel.
  ///
  /// In en, this message translates to:
  /// **'Feed'**
  String get feedTabLabel;

  /// No description provided for @connectionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get connectionsTitle;

  /// No description provided for @newPostTitle.
  ///
  /// In en, this message translates to:
  /// **'New post'**
  String get newPostTitle;

  /// No description provided for @profileTitle.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get profileTitle;

  /// No description provided for @inviteSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Invite'**
  String get inviteSectionTitle;

  /// No description provided for @copyTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copyTooltip;

  /// No description provided for @codeCopiedMessage.
  ///
  /// In en, this message translates to:
  /// **'Code copied'**
  String get codeCopiedMessage;

  /// No description provided for @createInviteCodeButton.
  ///
  /// In en, this message translates to:
  /// **'Create invite code'**
  String get createInviteCodeButton;

  /// No description provided for @createNewCodeButton.
  ///
  /// In en, this message translates to:
  /// **'Create new code'**
  String get createNewCodeButton;

  /// No description provided for @rotateInviteCodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Create a new code?'**
  String get rotateInviteCodeTitle;

  /// No description provided for @rotateInviteCodeContent.
  ///
  /// In en, this message translates to:
  /// **'The current code stops working immediately. Anyone you have already sent it to will not be able to use it.'**
  String get rotateInviteCodeContent;

  /// No description provided for @haveCodeSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'I have a code'**
  String get haveCodeSectionTitle;

  /// No description provided for @inviteCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Invite code'**
  String get inviteCodeLabel;

  /// No description provided for @inviteCodeRequiredError.
  ///
  /// In en, this message translates to:
  /// **'Enter an invite code'**
  String get inviteCodeRequiredError;

  /// No description provided for @inviteCodeNotFoundError.
  ///
  /// In en, this message translates to:
  /// **'Invite code not found. Check it and try again.'**
  String get inviteCodeNotFoundError;

  /// No description provided for @inviteCodeAlreadyUsedError.
  ///
  /// In en, this message translates to:
  /// **'This invite code has already been used.'**
  String get inviteCodeAlreadyUsedError;

  /// No description provided for @ownInviteCodeError.
  ///
  /// In en, this message translates to:
  /// **'That\'s your own invite code — share it with someone else.'**
  String get ownInviteCodeError;

  /// No description provided for @activateButton.
  ///
  /// In en, this message translates to:
  /// **'Activate'**
  String get activateButton;

  /// No description provided for @myConnectionsTitle.
  ///
  /// In en, this message translates to:
  /// **'My connections'**
  String get myConnectionsTitle;

  /// No description provided for @failedToLoadConnectionsError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load list. Please try again.'**
  String get failedToLoadConnectionsError;

  /// No description provided for @noConnectionsYetMessage.
  ///
  /// In en, this message translates to:
  /// **'No connections yet — activate a code or create one above'**
  String get noConnectionsYetMessage;

  /// No description provided for @nowConnectedWithMessage.
  ///
  /// In en, this message translates to:
  /// **'You\'re now connected with {name}'**
  String nowConnectedWithMessage(String name);

  /// No description provided for @favoriteFriendTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add to favorites'**
  String get favoriteFriendTooltip;

  /// No description provided for @unfavoriteFriendTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove from favorites'**
  String get unfavoriteFriendTooltip;

  /// No description provided for @muteFriendTooltip.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get muteFriendTooltip;

  /// No description provided for @unmuteFriendTooltip.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get unmuteFriendTooltip;

  /// No description provided for @muteFriendTitle.
  ///
  /// In en, this message translates to:
  /// **'Mute {name}?'**
  String muteFriendTitle(String name);

  /// No description provided for @muteFriendContent.
  ///
  /// In en, this message translates to:
  /// **'You won\'t see their posts in your feed. You\'ll still be connected.'**
  String get muteFriendContent;

  /// No description provided for @muteButton.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get muteButton;

  /// No description provided for @blockFriendTooltip.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get blockFriendTooltip;

  /// No description provided for @blockFriendTitle.
  ///
  /// In en, this message translates to:
  /// **'Block {name}?'**
  String blockFriendTitle(String name);

  /// No description provided for @blockFriendContent.
  ///
  /// In en, this message translates to:
  /// **'Neither of you will see each other\'s posts. You\'ll still be connected.'**
  String get blockFriendContent;

  /// No description provided for @blockButton.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get blockButton;

  /// No description provided for @unblockButton.
  ///
  /// In en, this message translates to:
  /// **'Unblock'**
  String get unblockButton;

  /// No description provided for @blockedUsersTooltip.
  ///
  /// In en, this message translates to:
  /// **'Blocked users'**
  String get blockedUsersTooltip;

  /// No description provided for @blockedUsersTitle.
  ///
  /// In en, this message translates to:
  /// **'Blocked'**
  String get blockedUsersTitle;

  /// No description provided for @noBlockedUsersMessage.
  ///
  /// In en, this message translates to:
  /// **'You haven\'t blocked anyone'**
  String get noBlockedUsersMessage;

  /// No description provided for @publishButton.
  ///
  /// In en, this message translates to:
  /// **'Publish'**
  String get publishButton;

  /// No description provided for @editPostTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit post'**
  String get editPostTitle;

  /// No description provided for @editButton.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get editButton;

  /// No description provided for @whatsNewHint.
  ///
  /// In en, this message translates to:
  /// **'What\'s new?'**
  String get whatsNewHint;

  /// No description provided for @addMediaButton.
  ///
  /// In en, this message translates to:
  /// **'Add photo or video'**
  String get addMediaButton;

  /// No description provided for @removeMediaTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get removeMediaTooltip;

  /// No description provided for @playVideoTooltip.
  ///
  /// In en, this message translates to:
  /// **'Play video'**
  String get playVideoTooltip;

  /// No description provided for @mediaLimitMessage.
  ///
  /// In en, this message translates to:
  /// **'You can add up to 20 photos or videos'**
  String get mediaLimitMessage;

  /// No description provided for @videoTooLongError.
  ///
  /// In en, this message translates to:
  /// **'Video must be under 60 seconds'**
  String get videoTooLongError;

  /// No description provided for @videoTooLargeError.
  ///
  /// In en, this message translates to:
  /// **'Video must be under 100 MB'**
  String get videoTooLargeError;

  /// No description provided for @failedToAddMediaError.
  ///
  /// In en, this message translates to:
  /// **'Some files couldn\'t be added'**
  String get failedToAddMediaError;

  /// No description provided for @unsupportedImageFormatError.
  ///
  /// In en, this message translates to:
  /// **'Unsupported image format. Use JPEG, PNG, WebP or HEIC.'**
  String get unsupportedImageFormatError;

  /// No description provided for @unsupportedVideoFormatError.
  ///
  /// In en, this message translates to:
  /// **'Unsupported video format. Use MP4, MOV, M4V, 3GP, WebM or MKV.'**
  String get unsupportedVideoFormatError;

  /// No description provided for @addTextOrPhotoError.
  ///
  /// In en, this message translates to:
  /// **'Add text, a photo, or a video'**
  String get addTextOrPhotoError;

  /// No description provided for @failedToPublishError.
  ///
  /// In en, this message translates to:
  /// **'Failed to publish. Please try again.'**
  String get failedToPublishError;

  /// No description provided for @failedToSaveChangesError.
  ///
  /// In en, this message translates to:
  /// **'Failed to save changes. Please try again.'**
  String get failedToSaveChangesError;

  /// No description provided for @deletePostTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete post?'**
  String get deletePostTitle;

  /// No description provided for @deletePostContent.
  ///
  /// In en, this message translates to:
  /// **'The post, its media, and comments will be deleted.'**
  String get deletePostContent;

  /// No description provided for @failedToLoadFeedError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load feed. Please try again.'**
  String get failedToLoadFeedError;

  /// No description provided for @failedToDeletePostError.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete post. Please try again.'**
  String get failedToDeletePostError;

  /// No description provided for @noPostsYetMessage.
  ///
  /// In en, this message translates to:
  /// **'No posts from connections yet. Add connections or write the first one.'**
  String get noPostsYetMessage;

  /// No description provided for @addConnectionsButton.
  ///
  /// In en, this message translates to:
  /// **'Add connections'**
  String get addConnectionsButton;

  /// No description provided for @myPostsTitle.
  ///
  /// In en, this message translates to:
  /// **'My posts'**
  String get myPostsTitle;

  /// No description provided for @noOwnPostsYetMessage.
  ///
  /// In en, this message translates to:
  /// **'You haven\'t posted anything yet'**
  String get noOwnPostsYetMessage;

  /// No description provided for @postsTitle.
  ///
  /// In en, this message translates to:
  /// **'Posts'**
  String get postsTitle;

  /// No description provided for @noAuthorPostsYetMessage.
  ///
  /// In en, this message translates to:
  /// **'This user hasn\'t posted anything yet'**
  String get noAuthorPostsYetMessage;

  /// No description provided for @likeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Like'**
  String get likeTooltip;

  /// No description provided for @neutralTooltip.
  ///
  /// In en, this message translates to:
  /// **'Neutral'**
  String get neutralTooltip;

  /// No description provided for @dislikeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Dislike'**
  String get dislikeTooltip;

  /// No description provided for @darkThemeToggleTooltip.
  ///
  /// In en, this message translates to:
  /// **'Toggle dark theme'**
  String get darkThemeToggleTooltip;

  /// No description provided for @failedToLoadProfileError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load profile. Please try again.'**
  String get failedToLoadProfileError;

  /// No description provided for @failedToSaveNameError.
  ///
  /// In en, this message translates to:
  /// **'Failed to save name. Please try again.'**
  String get failedToSaveNameError;

  /// No description provided for @addPhotoButton.
  ///
  /// In en, this message translates to:
  /// **'Add photo'**
  String get addPhotoButton;

  /// No description provided for @reorderPhotosButton.
  ///
  /// In en, this message translates to:
  /// **'Reorder'**
  String get reorderPhotosButton;

  /// No description provided for @deletePhotoButton.
  ///
  /// In en, this message translates to:
  /// **'Delete photo'**
  String get deletePhotoButton;

  /// No description provided for @reorderPhotosTitle.
  ///
  /// In en, this message translates to:
  /// **'Photo order'**
  String get reorderPhotosTitle;

  /// No description provided for @deletePhotosTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete photos'**
  String get deletePhotosTitle;

  /// No description provided for @photoLimitMessage.
  ///
  /// In en, this message translates to:
  /// **'You can add up to 80 photos'**
  String get photoLimitMessage;

  /// No description provided for @failedToLoadPhotosError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load photos. Please try again.'**
  String get failedToLoadPhotosError;

  /// No description provided for @failedToAddPhotosError.
  ///
  /// In en, this message translates to:
  /// **'Failed to add photos. Please try again.'**
  String get failedToAddPhotosError;

  /// No description provided for @failedToReorderPhotosError.
  ///
  /// In en, this message translates to:
  /// **'Failed to reorder photos. Please try again.'**
  String get failedToReorderPhotosError;

  /// No description provided for @failedToDeletePhotosError.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete photos. Please try again.'**
  String get failedToDeletePhotosError;

  /// No description provided for @deletePhotosConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete selected photos?'**
  String get deletePhotosConfirmTitle;

  /// No description provided for @deletePhotosConfirmContent.
  ///
  /// In en, this message translates to:
  /// **'The selected photos will be permanently deleted.'**
  String get deletePhotosConfirmContent;

  /// No description provided for @commentsTitle.
  ///
  /// In en, this message translates to:
  /// **'Comments'**
  String get commentsTitle;

  /// No description provided for @deleteCommentTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete comment?'**
  String get deleteCommentTitle;

  /// No description provided for @noCommentsYetMessage.
  ///
  /// In en, this message translates to:
  /// **'No comments yet'**
  String get noCommentsYetMessage;

  /// No description provided for @writeCommentHint.
  ///
  /// In en, this message translates to:
  /// **'Write a comment...'**
  String get writeCommentHint;

  /// No description provided for @writeReplyHint.
  ///
  /// In en, this message translates to:
  /// **'Write a reply...'**
  String get writeReplyHint;

  /// No description provided for @replyButton.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get replyButton;

  /// No description provided for @cancelReplyTooltip.
  ///
  /// In en, this message translates to:
  /// **'Cancel reply'**
  String get cancelReplyTooltip;

  /// No description provided for @replyingToLabel.
  ///
  /// In en, this message translates to:
  /// **'Replying to: {name}'**
  String replyingToLabel(String name);

  /// No description provided for @inReplyToLabel.
  ///
  /// In en, this message translates to:
  /// **'In reply to: {name}'**
  String inReplyToLabel(String name);

  /// No description provided for @deletedCommentPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Comment deleted'**
  String get deletedCommentPlaceholder;

  /// No description provided for @failedToLoadCommentsError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load comments. Please try again.'**
  String get failedToLoadCommentsError;

  /// No description provided for @failedToDeleteCommentError.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete comment. Please try again.'**
  String get failedToDeleteCommentError;

  /// No description provided for @failedToSendCommentError.
  ///
  /// In en, this message translates to:
  /// **'Failed to send. Please try again.'**
  String get failedToSendCommentError;

  /// No description provided for @commentsTruncatedNotice.
  ///
  /// In en, this message translates to:
  /// **'Showing the first {count} comments. Newer ones are not shown.'**
  String commentsTruncatedNotice(int count);

  /// No description provided for @connectionKnownLessThanDay.
  ///
  /// In en, this message translates to:
  /// **'Known for less than a day'**
  String get connectionKnownLessThanDay;

  /// No description provided for @connectionKnownDays.
  ///
  /// In en, this message translates to:
  /// **'Known for {days, plural, one{{days} day} other{{days} days}}'**
  String connectionKnownDays(int days);

  /// No description provided for @connectionKnownMonths.
  ///
  /// In en, this message translates to:
  /// **'Known for {months, plural, one{{months} month} other{{months} months}}'**
  String connectionKnownMonths(int months);

  /// No description provided for @connectionKnownYears.
  ///
  /// In en, this message translates to:
  /// **'Known for {years, plural, one{{years} year} other{{years} years}}'**
  String connectionKnownYears(int years);

  /// No description provided for @connectionSummary.
  ///
  /// In en, this message translates to:
  /// **'{duration}\nsince {date}'**
  String connectionSummary(String duration, String date);

  /// No description provided for @settingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTooltip;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @notificationsSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notificationsSectionTitle;

  /// No description provided for @notifyAppUpdatesLabel.
  ///
  /// In en, this message translates to:
  /// **'App update announcements'**
  String get notifyAppUpdatesLabel;

  /// No description provided for @notifyFavoritesLabel.
  ///
  /// In en, this message translates to:
  /// **'Posts from favorite friends'**
  String get notifyFavoritesLabel;

  /// No description provided for @notifyCommentsLabel.
  ///
  /// In en, this message translates to:
  /// **'Comments on your posts and replies to you'**
  String get notifyCommentsLabel;

  /// No description provided for @notifyDigestLabel.
  ///
  /// In en, this message translates to:
  /// **'Digest of posts from everyone else'**
  String get notifyDigestLabel;

  /// No description provided for @notifyInactiveLabel.
  ///
  /// In en, this message translates to:
  /// **'Reminders after a quiet week'**
  String get notifyInactiveLabel;

  /// No description provided for @failedToLoadSettingsError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load settings. Please try again.'**
  String get failedToLoadSettingsError;

  /// No description provided for @failedToSaveSettingsError.
  ///
  /// In en, this message translates to:
  /// **'Failed to save. Please try again.'**
  String get failedToSaveSettingsError;

  /// No description provided for @appVersionLabel.
  ///
  /// In en, this message translates to:
  /// **'Version {version} ({build})'**
  String appVersionLabel(String version, String build);

  /// No description provided for @languageSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageSectionTitle;

  /// No description provided for @languageSystemLabel.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get languageSystemLabel;

  /// No description provided for @accountSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get accountSectionTitle;

  /// No description provided for @signOutButton.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get signOutButton;

  /// No description provided for @signOutDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out?'**
  String get signOutDialogTitle;

  /// No description provided for @signOutDialogContent.
  ///
  /// In en, this message translates to:
  /// **'You\'ll need to sign in again to use the app.'**
  String get signOutDialogContent;

  /// No description provided for @failedToSignOutError.
  ///
  /// In en, this message translates to:
  /// **'Failed to sign out. Please try again.'**
  String get failedToSignOutError;

  /// No description provided for @deleteAccountLabel.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get deleteAccountLabel;

  /// No description provided for @deleteAccountDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete account?'**
  String get deleteAccountDialogTitle;

  /// No description provided for @deleteAccountDialogContent.
  ///
  /// In en, this message translates to:
  /// **'This is permanent: your profile, posts, comments, and connections will all be deleted. This can\'t be undone.'**
  String get deleteAccountDialogContent;

  /// No description provided for @failedToDeleteAccountError.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete account. Please try again.'**
  String get failedToDeleteAccountError;

  /// No description provided for @roomsTitle.
  ///
  /// In en, this message translates to:
  /// **'Rooms'**
  String get roomsTitle;

  /// No description provided for @roomFallbackName.
  ///
  /// In en, this message translates to:
  /// **'Room'**
  String get roomFallbackName;

  /// No description provided for @noRoomsYetMessage.
  ///
  /// In en, this message translates to:
  /// **'No rooms yet. A room is a separate chat for the people you invite into it.'**
  String get noRoomsYetMessage;

  /// No description provided for @newRoomTitle.
  ///
  /// In en, this message translates to:
  /// **'New room'**
  String get newRoomTitle;

  /// No description provided for @createRoomButton.
  ///
  /// In en, this message translates to:
  /// **'Create room'**
  String get createRoomButton;

  /// No description provided for @failedToLoadRoomsError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load rooms. Please try again.'**
  String get failedToLoadRoomsError;

  /// No description provided for @selectRoomMembersMessage.
  ///
  /// In en, this message translates to:
  /// **'Pick who joins. One person makes a room just for the two of you, and it can never take a third.'**
  String get selectRoomMembersMessage;

  /// No description provided for @pickAtLeastOneMemberError.
  ///
  /// In en, this message translates to:
  /// **'Pick at least one person.'**
  String get pickAtLeastOneMemberError;

  /// No description provided for @roomNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Room name'**
  String get roomNameLabel;

  /// No description provided for @roomNameHint.
  ///
  /// In en, this message translates to:
  /// **'Leave it empty to use the members\' names'**
  String get roomNameHint;

  /// No description provided for @failedToCreateRoomError.
  ///
  /// In en, this message translates to:
  /// **'Failed to create the room. Please try again.'**
  String get failedToCreateRoomError;

  /// No description provided for @notYourConnectionError.
  ///
  /// In en, this message translates to:
  /// **'You can only add your own connections to a room.'**
  String get notYourConnectionError;

  /// No description provided for @roomMembersTitle.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get roomMembersTitle;

  /// No description provided for @roomMembersCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 member} other{{count} members}}'**
  String roomMembersCount(int count);

  /// No description provided for @roomOwnerLabel.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get roomOwnerLabel;

  /// No description provided for @addMemberButton.
  ///
  /// In en, this message translates to:
  /// **'Add member'**
  String get addMemberButton;

  /// No description provided for @noConnectionsToAddMessage.
  ///
  /// In en, this message translates to:
  /// **'Everyone you know is already in this room.'**
  String get noConnectionsToAddMessage;

  /// No description provided for @removeMemberTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove from room'**
  String get removeMemberTooltip;

  /// No description provided for @removeMemberDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove {name}?'**
  String removeMemberDialogTitle(String name);

  /// No description provided for @removeMemberDialogContent.
  ///
  /// In en, this message translates to:
  /// **'They lose access to this room\'s feed. You can add them again later.'**
  String get removeMemberDialogContent;

  /// No description provided for @failedToUpdateRoomMembersError.
  ///
  /// In en, this message translates to:
  /// **'Failed to change the room\'s members. Please try again.'**
  String get failedToUpdateRoomMembersError;

  /// No description provided for @renameRoomTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename room'**
  String get renameRoomTitle;

  /// No description provided for @failedToRenameRoomError.
  ///
  /// In en, this message translates to:
  /// **'Failed to rename the room. Please try again.'**
  String get failedToRenameRoomError;

  /// No description provided for @leaveRoomButton.
  ///
  /// In en, this message translates to:
  /// **'Leave room'**
  String get leaveRoomButton;

  /// No description provided for @leaveRoomDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave room?'**
  String get leaveRoomDialogTitle;

  /// No description provided for @leaveRoomDialogContent.
  ///
  /// In en, this message translates to:
  /// **'The room disappears from your list and its conversation goes with it. Only the owner can bring you back.'**
  String get leaveRoomDialogContent;

  /// No description provided for @leaveDirectRoomDialogContent.
  ///
  /// In en, this message translates to:
  /// **'This room is just the two of you, so it goes for both — along with everything said in it.'**
  String get leaveDirectRoomDialogContent;

  /// No description provided for @failedToLeaveRoomError.
  ///
  /// In en, this message translates to:
  /// **'Failed to leave the room. Please try again.'**
  String get failedToLeaveRoomError;

  /// No description provided for @roomChatTitle.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get roomChatTitle;

  /// No description provided for @messageHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get messageHint;

  /// No description provided for @sendMessageTooltip.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get sendMessageTooltip;

  /// No description provided for @noMessagesYetMessage.
  ///
  /// In en, this message translates to:
  /// **'Quiet in here. Send the first message.'**
  String get noMessagesYetMessage;

  /// No description provided for @deletedMessageLabel.
  ///
  /// In en, this message translates to:
  /// **'Message deleted'**
  String get deletedMessageLabel;

  /// No description provided for @deleteMessageDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete message?'**
  String get deleteMessageDialogTitle;

  /// No description provided for @deleteMessageDialogContent.
  ///
  /// In en, this message translates to:
  /// **'It disappears for everyone in the room, leaving only a note.'**
  String get deleteMessageDialogContent;

  /// No description provided for @formerMemberLabel.
  ///
  /// In en, this message translates to:
  /// **'Former member'**
  String get formerMemberLabel;

  /// No description provided for @roomMessageStatusSentLabel.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get roomMessageStatusSentLabel;

  /// No description provided for @roomMessageStatusDeliveredLabel.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get roomMessageStatusDeliveredLabel;

  /// No description provided for @roomMessageStatusReadLabel.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get roomMessageStatusReadLabel;

  /// No description provided for @roomMessageReadCount.
  ///
  /// In en, this message translates to:
  /// **'Read {read}/{total}'**
  String roomMessageReadCount(int read, int total);

  /// No description provided for @roomMessageDeliveredCount.
  ///
  /// In en, this message translates to:
  /// **'Delivered {delivered}/{total}'**
  String roomMessageDeliveredCount(int delivered, int total);

  /// No description provided for @failedToLoadMessagesError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load messages. Please try again.'**
  String get failedToLoadMessagesError;

  /// No description provided for @failedToSendMessageError.
  ///
  /// In en, this message translates to:
  /// **'Failed to send. Please try again.'**
  String get failedToSendMessageError;

  /// No description provided for @failedToDeleteMessageError.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete the message. Please try again.'**
  String get failedToDeleteMessageError;

  /// No description provided for @notifyRoomMessagesLabel.
  ///
  /// In en, this message translates to:
  /// **'Messages in rooms'**
  String get notifyRoomMessagesLabel;

  /// No description provided for @roomAvatarLabel.
  ///
  /// In en, this message translates to:
  /// **'Room picture'**
  String get roomAvatarLabel;

  /// No description provided for @changeRoomAvatarButton.
  ///
  /// In en, this message translates to:
  /// **'Change picture'**
  String get changeRoomAvatarButton;

  /// No description provided for @removeRoomAvatarButton.
  ///
  /// In en, this message translates to:
  /// **'Remove picture'**
  String get removeRoomAvatarButton;

  /// No description provided for @failedToUpdateRoomAvatarError.
  ///
  /// In en, this message translates to:
  /// **'Failed to change the room picture. Please try again.'**
  String get failedToUpdateRoomAvatarError;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
