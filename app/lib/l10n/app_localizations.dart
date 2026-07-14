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
  /// **'Unexpected error: {error}'**
  String unexpectedError(Object error);

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
  /// **'Failed to load list: {error}'**
  String failedToLoadConnectionsError(Object error);

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

  /// No description provided for @publishButton.
  ///
  /// In en, this message translates to:
  /// **'Publish'**
  String get publishButton;

  /// No description provided for @whatsNewHint.
  ///
  /// In en, this message translates to:
  /// **'What\'s new?'**
  String get whatsNewHint;

  /// No description provided for @addPhotoButton.
  ///
  /// In en, this message translates to:
  /// **'Add photo'**
  String get addPhotoButton;

  /// No description provided for @replacePhotoButton.
  ///
  /// In en, this message translates to:
  /// **'Replace photo'**
  String get replacePhotoButton;

  /// No description provided for @addTextOrPhotoError.
  ///
  /// In en, this message translates to:
  /// **'Add text or a photo'**
  String get addTextOrPhotoError;

  /// No description provided for @failedToPublishError.
  ///
  /// In en, this message translates to:
  /// **'Failed to publish: {error}'**
  String failedToPublishError(Object error);

  /// No description provided for @deletePostTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete post?'**
  String get deletePostTitle;

  /// No description provided for @deletePostContent.
  ///
  /// In en, this message translates to:
  /// **'The post, its photo, and comments will be deleted.'**
  String get deletePostContent;

  /// No description provided for @failedToLoadFeedError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load feed: {error}'**
  String failedToLoadFeedError(Object error);

  /// No description provided for @failedToDeletePostError.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete post: {error}'**
  String failedToDeletePostError(Object error);

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

  /// No description provided for @signOutTooltip.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get signOutTooltip;

  /// No description provided for @darkThemeToggleTooltip.
  ///
  /// In en, this message translates to:
  /// **'Toggle dark theme'**
  String get darkThemeToggleTooltip;

  /// No description provided for @failedToLoadProfileError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load profile: {error}'**
  String failedToLoadProfileError(Object error);

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

  /// No description provided for @failedToLoadCommentsError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load comments: {error}'**
  String failedToLoadCommentsError(Object error);

  /// No description provided for @failedToDeleteCommentError.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete comment: {error}'**
  String failedToDeleteCommentError(Object error);

  /// No description provided for @failedToSendCommentError.
  ///
  /// In en, this message translates to:
  /// **'Failed to send: {error}'**
  String failedToSendCommentError(Object error);

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
  /// **'{duration} — since {date}'**
  String connectionSummary(String duration, String date);
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
